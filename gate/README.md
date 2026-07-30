# Phase 4 gate: end to end validation on real infrastructure

This directory holds the scaffolding for Subphase 4.5, the gate of Phase 4. It
runs the naylamp cluster on three separate Linux hosts over a real network and
subjects it to real failures (kill -9 of a leader, a real network partition),
observing that the cluster keeps serving the public API. The correctness of the
logic is still judged by the seeded DST; this gate validates operability and
deployment on real infrastructure, which is the only place the project allows an
Exceptional grade to be claimed.

Design note: the roadmap named a `deploy.go`, but Subphase 4.5 forbids new
external dependencies, and driving real ssh from Go would need x/crypto/ssh (a
new dependency) or shelling out to ssh anyway. So the orchestration is portable
bash over ssh and scp, with no dependency the module does not already have. This
deviation and its reason are recorded here and in the subphase closure.

## Topology of the scenario

- One shard group of three replicas, ids 1, 2, 3, each listening on its private
  ip at port 9401.
- The routing client is id 90. It always runs on host 1, listening on the host 1
  private ip at port 9490, because the nodes dial the client back by address and
  a laptop behind NAT would be unreachable. The client address is wired into the
  nodes at launch, so its host is fixed for the run.
- The benchmark topology (Subphase 4.5-B) is decided after reading the 3.5
  benchmark; these scripts cover only the failure scenario.

## Files

- `common.sh` - environment validation and the ssh and scp helpers, sourced by
  the others.
- `build.sh` - build naylampd for linux, cross compile the demo naylamp for linux
  (the faultlog injector the log-fidelity gate needs on the hosts), and mint
  certificates, all local.
- `deploy.sh` - push both binaries and each host's certificate material.
- `cluster.sh` - start, stop, status, start-node, stop-node.
- `partition.sh` - apply, heal, status of a real iptables partition.
- `readindex.sh` - the read-index gate (Subphase 4.3): a linearizable read is
  served only after a confirmed majority round, and withheld under isolation. It
  runs standalone, and `omnibus.sh` drives it as the first arm of its audit, which
  is what puts this property under the same commit as the rest of an `all` run;
  the `NAYLAMP_READINDEX_*` variables that make that possible are in the script
  header.
- `tls.sh` - the mutual TLS gate (Subphase 4.4): a forged identity is rejected and
  the raft traffic carries no framing magic in the clear.
- `faithlog.sh` - the log-fidelity gate (Subphase 4.2): each replica's committed
  log verifies as a faithful record of a known workload, and four injected defects
  (phantom, missing, corrupt, and an idempotent duplicate as the negative control)
  prove the checker reds for the right reason. Build and gate run under one tee into
  `NAYLAMP_FAITHLOG_GATE_<date>.txt`; the runbook is in the script header.
- `checkquorum.sh` - the CheckQuorum gate (Subphase 4.1): a leader that can reach
  no majority steps down, and the arm with the older binary shows the check reds
  for the right reason.
- `servicehealth.sh` - the service-health gate (Subphase 4.1): the same fleet with
  the feature switched off is the arm that makes the green mean something.
- `omnibus.sh` - the Subphase 4.5 gate widened with the Arc 4.8 invariant audit,
  in six phases from an off-cloud precondition to a hygiene check. It is the only
  gate here that grades a whole phase. It has no default subcommand, because it
  wipes the data directories on all three hosts. The provenance phase records the
  commit HEAD sat at, and that is what ties a run's verdicts to a tree; only `all`
  and `provenance` run it, so any other single subcommand names no tree and says
  so.

Everything the gate scripts build or write locally lands in `gate/out`, which is
ignored, and `make clean` empties it except for `gate/out/certs`: `build.sh` mints
those identities once and reuses them, so clearing them without running
`deploy.sh` afterwards leaves the hosts on the old CA. The `NAYLAMP_*GATE*.txt`
run artifacts live outside `gate/out` and `make clean` never looks at them.

## Environment (all four, fail loud if missing)

    export NAYLAMP_GATE_HOSTS=<pub1>,<pub2>,<pub3>     # public ips, id order 1,2,3
    export NAYLAMP_GATE_PRIVATE=<priv1>,<priv2>,<priv3> # private ips, same order
    export NAYLAMP_GATE_KEY=/path/to/key.pem           # the ssh private key
    export NAYLAMP_GATE_USER=ubuntu                     # default, override if needed

The public ips are for ssh from this machine; the private ips are what the nodes
use to reach each other and the client, and must be inside the same VPC subnet.

## Runbook

Capture each step's output into the run artifact, which is gitignored:

    ... | tee -a NAYLAMP_PHASE4_GATE.txt

### 0. Prerequisites

- Three Linux hosts (Ubuntu 24.04) in the same private network with a cloud
  provider (AWS EC2, Azure VMs, or equivalent).
- The provider firewall allows: ssh (22) from your ip; TCP 9401 and 9490 among
  the three private ips (a rule that lets the three hosts reach each other is the
  simplest). Without 9401 open between the private ips the cluster cannot form
  quorum; without 9490 the nodes cannot answer the client.
- The key file is chmod 600 and matches the instances' key pair.
- The four environment variables above are exported.

### 1. Build (local)

    ./gate/build.sh

Evidence to capture: the final `file` line, which must show naylampd as an ELF
64 bit LSB executable, statically linked. Certificates are minted once into
`gate/out/certs`.

### 2. Deploy

    ./gate/deploy.sh

Pushes naylampd and certificates to the three hosts under `~/naylamp`. Host 1
also receives the id 90 client material. Re-running is safe.

### 3. Round trip time (the deadline observation promised by 4.4 RISK 3)

    IFS=',' read -r P1 P2 P3 <<< "$NAYLAMP_GATE_PRIVATE"
    H1="$(echo "$NAYLAMP_GATE_HOSTS" | cut -d, -f1)"
    ssh -i "$NAYLAMP_GATE_KEY" "$NAYLAMP_GATE_USER@$H1" "ping -c 5 $P2; ping -c 5 $P3"

Evidence: the RTT. On a single VPC subnet it is sub-millisecond. The transport's
socket timeout is 30 seconds, so a healthy link sits roughly five orders of
magnitude below the deadline; the deadline never trips a healthy peer under real
network latency here. 4.4 KNOWN RISK 3 asked to measure this in 4.5; this is the
measurement. Under a high latency WAN the same 30 second budget still holds with
wide margin.

### 4. Start the cluster

    ./gate/cluster.sh start
    ./gate/cluster.sh status

Repeat status until exactly one node reports `role=leader leader=<id>` and the
others report the same `leader=<id>`. Evidence: the status output showing an
elected leader.

### 5. Base scenario: write and read through the API

Define the client invocations (they run on host 1, as id 90):

    IFS=',' read -r P1 P2 P3 <<< "$NAYLAMP_GATE_PRIVATE"
    H1="$(echo "$NAYLAMP_GATE_HOSTS" | cut -d, -f1)"
    GROUP="1=$P1:9401,2=$P2:9401,3=$P3:9401"
    CLI="cd naylamp && NAYLAMP_TLS_CERT=certs/node-90.pem NAYLAMP_TLS_KEY=certs/node-90-key.pem NAYLAMP_TLS_CA=certs/ca.pem ./bin/naylampd client -listen $P1:9490 -group '$GROUP'"

Put a known vector, then search it back:

    ssh -i "$NAYLAMP_GATE_KEY" "$NAYLAMP_GATE_USER@$H1" "$CLI -op put -id 7 -vec 1,0,0 -deadline 20s; echo exit=\$?"
    ssh -i "$NAYLAMP_GATE_KEY" "$NAYLAMP_GATE_USER@$H1" "$CLI -op search -vec 1,0,0 -k 3 -deadline 20s; echo exit=\$?"

Evidence: the put prints `ok index=<n>` with `exit=0`; the search prints a line
containing `id=7` with `exit=0`. That is read your writes across three real
hosts, which is quorum observed end to end.

### 6. Real failure 1: kill -9 of the leader

    ./gate/cluster.sh status                 # note the leader, say it is node L

Kill the leader's process on its host (substitute L and its public ip):

    HL="$(echo "$NAYLAMP_GATE_HOSTS" | cut -d, -f L)"
    ssh -i "$NAYLAMP_GATE_KEY" "$NAYLAMP_GATE_USER@$HL" 'kill -9 $(cat naylamp/naylampd.pid); echo killed'

Then watch a new leader emerge among the two survivors and read the same id back:

    ./gate/cluster.sh status                 # repeat until a survivor is leader
    ssh -i "$NAYLAMP_GATE_KEY" "$NAYLAMP_GATE_USER@$H1" "$CLI -op search -vec 1,0,0 -k 3 -deadline 20s; echo exit=\$?"

Reintegrate the killed node as a follower:

    ./gate/cluster.sh start-node L
    ./gate/cluster.sh status

Evidence: the kill; a new `role=leader` on a survivor; the search returning
`id=7` with `exit=0` after the failover (read your writes survived the leader
loss); the rejoined node showing `role=follower`.

### 7. Real failure 2: network partition (with the leader relocation rule)

The client lives on host 1, so host 1 must never be the partitioned node. Before
partitioning, force the leader off host 1 if it landed there:

    ./gate/cluster.sh status                 # if the leader is node 1, do this cycle:
    H1="$(echo "$NAYLAMP_GATE_HOSTS" | cut -d, -f1)"
    ssh -i "$NAYLAMP_GATE_KEY" "$NAYLAMP_GATE_USER@$H1" 'kill -9 $(cat naylamp/naylampd.pid); echo killed'
    ./gate/cluster.sh status                 # wait for a new leader, which can only be 2 or 3
    ./gate/cluster.sh start-node 1           # node 1 rejoins as a follower and does not usurp a stable leader

That extra kill cycle is itself captured as additional failover evidence. Now the
leader is guaranteed to be node 2 or node 3. Partition it (substitute the leader
id L in {2,3}):

    ./gate/partition.sh apply L
    ./gate/cluster.sh status                 # the isolated node loses leadership; the majority elects a new leader
    ssh -i "$NAYLAMP_GATE_KEY" "$NAYLAMP_GATE_USER@$H1" "$CLI -op search -vec 1,0,0 -k 3 -deadline 20s; echo exit=\$?"

Heal and confirm reconvergence:

    ./gate/partition.sh heal L
    ./gate/cluster.sh status                 # the healed node rejoins and the cluster reconverges
    ssh -i "$NAYLAMP_GATE_KEY" "$NAYLAMP_GATE_USER@$H1" "$CLI -op search -vec 1,0,0 -k 3 -deadline 20s; echo exit=\$?"

Evidence: the applied iptables rules; the majority serving `id=7` with `exit=0`
while a node is isolated; the healed rules removed; the search still `exit=0`
after reconvergence.

### 8. Close

- Benchmark on real infrastructure: the 4.5-B piece (placeholder here). It will
  add `engine/naylamp/realinfra_bench_test.go` and its own topology.
- Assemble the final results table into `NAYLAMP_PHASE4_GATE.txt`, comparing the
  failover, throughput, and scatter-gather numbers against the simulated 3.5
  numbers, and stop the cluster:

      ./gate/cluster.sh stop

## Partition alternative: provider firewall rules (AWS Security Groups, Azure NSGs)

Instead of iptables on the host, a partition can be induced at the network layer
through the provider's firewall. On AWS, move the target instance to a security
group that denies the private ips of its two peers, or remove the allow rule for
9401 to that instance. On Azure, apply a network security group rule that denies
those private ips. This is arguably a more real partition (enforced by the
network, not the host), at the cost of being slower to apply and heal through the
provider API or console. iptables is the default here because it is fast,
scriptable, and local to the host under test.

## Troubleshooting

- Quorum never forms: check that 9401 is open between the three private ips in
  the provider firewall, and that `cluster.sh status` shows role lines at all (if
  it shows "no role line yet", the node did not start; read `~/naylamp/logs/node.log`).
- The client hangs or times out: check that 9490 is open to host 1 from the node
  private ips, and that the client material (node-90) reached host 1.
- Permission denied on ssh: the key must be chmod 600 and match the key pair.
- iptables says permission denied: the commands use sudo; the provider's ubuntu
  user has passwordless sudo by default.
- The public ips changed: a provider VM's public ip can change across stop and
  start, while the private ip persists. Recapture NAYLAMP_GATE_HOSTS from the
  provider console after a restart; NAYLAMP_GATE_PRIVATE stays the same.

## Cost note

Small cloud instances bill while running. Stop the three instances between
sessions to avoid charges; the data dirs and certificates persist on the attached
volumes, so a later session resumes after recapturing the public ips.
