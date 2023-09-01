# compile time options here
const
  libp2p_pubsub_sign {.booldefine.} = true
  libp2p_pubsub_verify {.booldefine.} = true
  libp2p_pubsub_anonymize {.booldefine.} = false

import hashes, random, tables, sets, sequtils
import chronos, stew/[byteutils, results]
import ../../libp2p/[builders,
                     protocols/pubsub/errors,
                     protocols/pubsub/pubsub,
                     protocols/pubsub/gossipsub,
                     protocols/pubsub/floodsub,
                     protocols/pubsub/rpc/messages,
                     protocols/secure/secure]
import chronicles

export builders

randomize()

func defaultMsgIdProvider*(m: Message): Result[MessageId, ValidationResult] =
  let mid =
    if m.seqno.len > 0 and m.fromPeer.data.len > 0:
      byteutils.toHex(m.seqno) & $m.fromPeer
    else:
      # This part is irrelevant because it's not standard,
      # We use it exclusively for testing basically and users should
      # implement their own logic in the case they use anonymization
      $m.data.hash & $m.topicIds.hash
  ok mid.toBytes()

proc generateNodes*(
  num: Natural,
  secureManagers: openArray[SecureProtocol] = [
    SecureProtocol.Noise
  ],
  msgIdProvider: MsgIdProvider = defaultMsgIdProvider,
  gossip: bool = false,
  triggerSelf: bool = false,
  verifySignature: bool = libp2p_pubsub_verify,
  anonymize: bool = libp2p_pubsub_anonymize,
  sign: bool = libp2p_pubsub_sign,
  validationStrategy: ValidationStrategy = ValidationStrategy.Parallel,
  sendSignedPeerRecord = false,
  unsubscribeBackoff = 1.seconds,
  maxMessageSize: int = 1024 * 1024,
  enablePX: bool = false): seq[PubSub] =

  for i in 0..<num:
    let switch = newStandardSwitch(secureManagers = secureManagers, sendSignedPeerRecord = sendSignedPeerRecord)
    let pubsub = if gossip:
      let g = GossipSub.init(
        switch = switch,
        triggerSelf = triggerSelf,
        verifySignature = verifySignature,
        sign = sign,
        validationStrategy = validationStrategy,
        msgIdProvider = msgIdProvider,
        anonymize = anonymize,
        maxMessageSize = maxMessageSize,
        parameters = (var p = GossipSubParams.init(); p.floodPublish = false; p.historyLength = 20; p.historyGossip = 20; p.unsubscribeBackoff = unsubscribeBackoff; p.enablePX = enablePX; p))
      # set some testing params, to enable scores
      g.topicParams.mgetOrPut("foobar", TopicParams.init()).topicWeight = 1.0
      g.topicParams.mgetOrPut("foo", TopicParams.init()).topicWeight = 1.0
      g.topicParams.mgetOrPut("bar", TopicParams.init()).topicWeight = 1.0
      g.PubSub
    else:
      FloodSub.init(
        switch = switch,
        triggerSelf = triggerSelf,
        verifySignature = verifySignature,
        sign = sign,
        msgIdProvider = msgIdProvider,
        maxMessageSize = maxMessageSize,
        anonymize = anonymize).PubSub

    switch.mount(pubsub)
    result.add(pubsub)

proc subscribeNodes*(nodes: seq[PubSub]) {.async.} =
  for dialer in nodes:
    for node in nodes:
      if dialer.switch.peerInfo.peerId != node.switch.peerInfo.peerId:
        await dialer.switch.connect(node.peerInfo.peerId, node.peerInfo.addrs)

proc subscribeSparseNodes*(nodes: seq[PubSub], degree: int = 2) {.async.} =
  if nodes.len < degree:
    raise (ref CatchableError)(msg: "nodes count needs to be greater or equal to degree!")

  for i, dialer in nodes:
    if (i mod degree) != 0:
      continue

    for node in nodes:
      if dialer.switch.peerInfo.peerId != node.peerInfo.peerId:
        await dialer.switch.connect(node.peerInfo.peerId, node.peerInfo.addrs)

proc subscribeRandom*(nodes: seq[PubSub]) {.async.} =
  for dialer in nodes:
    var dialed: seq[PeerId]
    while dialed.len < nodes.len - 1:
      let node = sample(nodes)
      if node.peerInfo.peerId notin dialed:
        if dialer.peerInfo.peerId != node.peerInfo.peerId:
          await dialer.switch.connect(node.peerInfo.peerId, node.peerInfo.addrs)
          dialed.add(node.peerInfo.peerId)

proc waitSub*(sender, receiver: auto; key: string) {.async, gcsafe.} =
  if sender == receiver:
    return
  let timeout = Moment.now() + 5.seconds
  let fsub = GossipSub(sender)

  # this is for testing purposes only
  # peers can be inside `mesh` and `fanout`, not just `gossipsub`
  while (not fsub.gossipsub.hasKey(key) or
         not fsub.gossipsub.hasPeerId(key, receiver.peerInfo.peerId)) and
        (not fsub.mesh.hasKey(key) or
         not fsub.mesh.hasPeerId(key, receiver.peerInfo.peerId)) and
        (not fsub.fanout.hasKey(key) or
         not fsub.fanout.hasPeerId(key , receiver.peerInfo.peerId)):
    trace "waitSub sleeping..."

    # await
    await sleepAsync(5.milliseconds)
    doAssert Moment.now() < timeout, "waitSub timeout!"

proc waitSubGraph*(nodes: seq[PubSub], key: string) {.async, gcsafe.} =
  let timeout = Moment.now() + 5.seconds
  while true:
    var
      nodesMesh: Table[PeerId, seq[PeerId]]
      seen: HashSet[PeerId]
    for n in nodes:
      nodesMesh[n.peerInfo.peerId] = toSeq(GossipSub(n).mesh.getOrDefault(key).items()).mapIt(it.peerId)
    var ok = 0
    for n in nodes:
      seen.clear()
      proc explore(p: PeerId) =
        if p in seen: return
        seen.incl(p)
        for peer in nodesMesh.getOrDefault(p):
          explore(peer)
      explore(n.peerInfo.peerId)
      if seen.len == nodes.len: ok.inc()
    if ok == nodes.len: return
    trace "waitSubGraph sleeping..."

    await sleepAsync(5.milliseconds)
    doAssert Moment.now() < timeout, "waitSubGraph timeout!"
