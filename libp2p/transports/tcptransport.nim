# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## TCP transport implementation

{.push raises: [].}

import std/[sequtils]
import stew/results
import chronos, chronicles
import transport,
       ../errors,
       ../wire,
       ../multicodec,
       ../connmanager,
       ../multiaddress,
       ../stream/connection,
       ../stream/chronosstream,
       ../upgrademngrs/upgrade,
       ../utility

logScope:
  topics = "libp2p tcptransport"

export transport, results

const
  TcpTransportTrackerName* = "libp2p.tcptransport"

type
  TcpTransport* = ref object of Transport
    servers*: seq[StreamServer]
    clients: array[Direction, seq[StreamTransport]]
    flags: set[ServerFlags]
    clientFlags: set[SocketFlags]
    acceptFuts: seq[Future[StreamTransport]]
    connectionsTimeout: Duration

  TcpTransportTracker* = ref object of TrackerBase
    opened*: uint64
    closed*: uint64

  TcpTransportError* = object of transport.TransportError

proc setupTcpTransportTracker(): TcpTransportTracker {.gcsafe, raises: [].}

proc getTcpTransportTracker(): TcpTransportTracker {.gcsafe.} =
  result = cast[TcpTransportTracker](getTracker(TcpTransportTrackerName))
  if isNil(result):
    result = setupTcpTransportTracker()

proc dumpTracking(): string {.gcsafe.} =
  var tracker = getTcpTransportTracker()
  result = "Opened tcp transports: " & $tracker.opened & "\n" &
           "Closed tcp transports: " & $tracker.closed

proc leakTransport(): bool {.gcsafe.} =
  var tracker = getTcpTransportTracker()
  result = (tracker.opened != tracker.closed)

proc setupTcpTransportTracker(): TcpTransportTracker =
  result = new TcpTransportTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpTracking
  result.isLeaked = leakTransport
  addTracker(TcpTransportTrackerName, result)

proc connHandler*(self: TcpTransport,
                  client: StreamTransport,
                  observedAddr: Opt[MultiAddress],
                  dir: Direction): Future[Connection] {.async.} =

  trace "Handling tcp connection", address = $observedAddr,
                                   dir = $dir,
                                   clients = self.clients[Direction.In].len +
                                   self.clients[Direction.Out].len

  let conn = Connection(
    ChronosStream.init(
      client = client,
      dir = dir,
      observedAddr = observedAddr,
      timeout = self.connectionsTimeout
    ))

  proc onClose() {.async.} =
    try:
      let futs = @[client.join(), conn.join()]
      await futs[0] or futs[1]
      for f in futs:
        if not f.finished: await f.cancelAndWait() # cancel outstanding join()

      trace "Cleaning up client", addrs = $client.remoteAddress,
                                  conn

      self.clients[dir].keepItIf( it != client )
      await allFuturesThrowing(
        conn.close(), client.closeWait())

      trace "Cleaned up client", addrs = $client.remoteAddress,
                                 conn

    except CatchableError as exc:
      let useExc {.used.} = exc
      debug "Error cleaning up client", errMsg = exc.msg, conn

  self.clients[dir].add(client)
  asyncSpawn onClose()

  return conn

proc new*(
  T: typedesc[TcpTransport],
  flags: set[ServerFlags] = {},
  upgrade: Upgrade,
  connectionsTimeout = 10.minutes): T {.public.} =

  let
    transport = T(
      flags: flags,
      clientFlags:
        if ServerFlags.TcpNoDelay in flags:
          compilesOr:
            {SocketFlags.TcpNoDelay}
          do:
            doAssert(false)
            default(set[SocketFlags])
        else:
          default(set[SocketFlags]),
      upgrader: upgrade,
      networkReachability: NetworkReachability.Unknown,
      connectionsTimeout: connectionsTimeout)

  return transport

method start*(
  self: TcpTransport,
  addrs: seq[MultiAddress]) {.async.} =
  ## listen on the transport
  ##

  if self.running:
    warn "TCP transport already running"
    return

  await procCall Transport(self).start(addrs)
  trace "Starting TCP transport"
  inc getTcpTransportTracker().opened

  for i, ma in addrs:
    if not self.handles(ma):
      trace "Invalid address detected, skipping!", address = ma
      continue

    self.flags.incl(ServerFlags.ReusePort)
    let server = createStreamServer(
      ma = ma,
      flags = self.flags,
      udata = self)

    # always get the resolved address in case we're bound to 0.0.0.0:0
    self.addrs[i] = MultiAddress.init(
      server.sock.getLocalAddress()
    ).tryGet()

    self.servers &= server

    trace "Listening on", address = ma

method stop*(self: TcpTransport) {.async.} =
  ## stop the transport
  ##
  try:
    trace "Stopping TCP transport"

    checkFutures(
      await allFinished(
        self.clients[Direction.In].mapIt(it.closeWait()) &
        self.clients[Direction.Out].mapIt(it.closeWait())))

    if not self.running:
      warn "TCP transport already stopped"
      return

    await procCall Transport(self).stop() # call base
    var toWait: seq[Future[void]]
    for fut in self.acceptFuts:
      if not fut.finished:
        toWait.add(fut.cancelAndWait())
      elif fut.done:
        toWait.add(fut.read().closeWait())

    for server in self.servers:
      server.stop()
      toWait.add(server.closeWait())

    await allFutures(toWait)

    self.servers = @[]

    trace "Transport stopped"
    inc getTcpTransportTracker().closed
  except CatchableError as exc:
    trace "Error shutting down tcp transport", exc = exc.msg

method accept*(self: TcpTransport): Future[Connection] {.async.} =
  ## accept a new TCP connection
  ##

  if not self.running:
    raise newTransportClosedError()

  try:
    if self.acceptFuts.len <= 0:
      self.acceptFuts = self.servers.mapIt(Future[StreamTransport](it.accept()))

    if self.acceptFuts.len <= 0:
      return

    let
      finished = await one(self.acceptFuts)
      index = self.acceptFuts.find(finished)

    self.acceptFuts[index] = self.servers[index].accept()

    let transp = await finished
    try:
      let observedAddr = MultiAddress.init(transp.remoteAddress).tryGet()
      return await self.connHandler(transp, Opt.some(observedAddr), Direction.In)
    except CancelledError as exc:
      transp.close()
      raise exc
    except CatchableError as exc:
      debug "Failed to handle connection", exc = exc.msg
      transp.close()
  except TransportTooManyError as exc:
    debug "Too many files opened", exc = exc.msg
  except TransportAbortedError as exc:
    debug "Connection aborted", exc = exc.msg
  except TransportUseClosedError as exc:
    debug "Server was closed", exc = exc.msg
    raise newTransportClosedError(exc)
  except CancelledError as exc:
    raise exc
  except TransportOsError as exc:
    info "OS Error", exc = exc.msg
    raise exc
  except CatchableError as exc:
    info "Unexpected error accepting connection", exc = exc.msg
    raise exc

method dial*(
  self: TcpTransport,
  hostname: string,
  address: MultiAddress,
  peerId: Opt[PeerId] = Opt.none(PeerId)): Future[Connection] {.async.} =
  ## dial a peer
  ##

  trace "Dialing remote peer", address = $address
  let transp =
    if self.networkReachability == NetworkReachability.NotReachable and self.addrs.len > 0:
      self.clientFlags.incl(SocketFlags.ReusePort)
      await connect(address, flags = self.clientFlags, localAddress = Opt.some(self.addrs[0]))
    else:
      await connect(address, flags = self.clientFlags)

  try:
    let observedAddr = MultiAddress.init(transp.remoteAddress).tryGet()
    return await self.connHandler(transp, Opt.some(observedAddr), Direction.Out)
  except CatchableError as err:
    await transp.closeWait()
    raise err

method handles*(t: TcpTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    if address.protocols.isOk:
      return TCP.match(address)
