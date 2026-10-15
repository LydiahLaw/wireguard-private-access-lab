# WireGuard private access lab

A small lab that recreates how connector-based private access works: a user on a laptop reaches an internal web app through a WireGuard tunnel, without that app ever being exposed. I then broke the setup four different ways and diagnosed each one using `wg show`, `tcpdump`, iptables counters and the Windows routing table.

I built this to get hands-on with WireGuard after working with IPsec (IKEv2) tunnels in production. Everything runs on one Windows 10 laptop.

## Architecture

```
Windows 10 (WireGuard app)  --tunnel, UDP 51820-->  WSL2 Ubuntu (connector)  -->  namespace "private"
10.99.0.2                                           wg0: 10.99.0.1                  10.20.0.2:8080 (web app)
                                                    veth-conn: 10.20.0.1
```

| Component | Role |
|---|---|
| Windows WireGuard app | The client, as an end user would run it |
| WSL2 Ubuntu 24.04 | The connector. It terminates the tunnel and routes traffic into the private network |
| Linux network namespace `private` | Stands in for an internal network. Windows has no route to it except through the tunnel |
| veth pair | A virtual cable between the connector and the private network |
| Python http.server | The internal app |

| Network | Purpose |
|---|---|
| 10.99.0.0/24 | Tunnel addresses |
| 10.20.0.0/24 | Private network |

## Key ideas

WireGuard compared with IPsec, which I already knew:

| | IPsec (IKEv2) | WireGuard |
|---|---|---|
| Ports | UDP 500 and 4500, plus ESP | One UDP port (51820 here) |
| Crypto | Negotiated by IKE in phases | Fixed (Curve25519, ChaCha20-Poly1305) |
| Identity | Certificates or pre-shared keys | One key pair per peer |

AllowedIPs does two jobs. When sending, it acts as a routing table that decides which destinations go into the tunnel. When receiving, it acts as an access list that decides which source IPs a peer is allowed to use. Split tunneling is just a choice of AllowedIPs.

WireGuard does not reply to packets it can't authenticate. A wrong key or a blocked port produces silence, not an error. The first thing to check is the `latest handshake` line in `wg show`. No handshake points to keys, the endpoint or a firewall. A handshake with no traffic points to AllowedIPs, routing or forwarding.

## Build steps

### 1. Install and generate keys

```bash
sudo apt install -y wireguard-tools tcpdump
sudo modprobe wireguard
umask 077
wg genkey | tee connector.key | wg pubkey > connector.pub
```

The WSL2 kernel ships WireGuard as a module (`CONFIG_WIREGUARD=m`), so it only needed loading. The Windows app generates its own key pair. Only public keys were exchanged between the two sides.

![Windows client config](screenshots/01-windows-client-config.png)

### 2. Bring up the connector

Config files are in [configs/](configs/), with keys replaced by placeholders.

```bash
sudo wg-quick up wg0
sudo wg show
```

Before the client connects, the peer is listed with no endpoint and no handshake.

![Connector up](screenshots/02-connector-wg-up.png)

### 3. First handshake

I activated the tunnel on Windows and pinged 10.99.0.1 while capturing on the connector.

```bash
sudo tcpdump -ni eth0 udp port 51820
```

![Handshake and tcpdump](screenshots/03-handshake-tcpdump.png)

WireGuard packet sizes are fixed, so tcpdump shows what is happening without decrypting anything:

| Length | Packet |
|---|---|
| 148 | Handshake initiation |
| 92 | Handshake response |
| 32 | Keepalive |
| 96 | Data (here, an encrypted ping) |

The connector learned the client's endpoint from the handshake. I never configured it. If the client's address or port changes, WireGuard updates it on the next valid packet.

### 4. Private network and app

[scripts/setup-private-network.sh](scripts/setup-private-network.sh) creates the namespace, the veth pair, the routes and the web app. The namespace's default route points at the connector, so replies to 10.99.0.2 find their way back through the tunnel. There is no NAT, so the app sees the client's tunnel IP.

The app loading in the browser on Windows, with every packet crossing both `wg0` and `veth-conn`:

![Private app via tunnel](screenshots/04-private-app-via-tunnel.png)

With the tunnel deactivated, the app is unreachable:

![Tunnel down](screenshots/05-private-app-tunnel-down.png)

### 5. Split tunneling

```powershell
Find-NetRoute -RemoteIPAddress 10.20.0.2 | Select-Object -Last 1 InterfaceAlias, DestinationPrefix
Find-NetRoute -RemoteIPAddress 8.8.8.8 | Select-Object -Last 1 InterfaceAlias, DestinationPrefix
```

Private traffic goes through `wg-lab`. Internet traffic stays on Wi-Fi. Windows created the 10.20.0.0/24 route from the client's AllowedIPs.

![Split tunnel routes](screenshots/06-split-tunnel-routes.png)

Setting AllowedIPs to `0.0.0.0/0` would make it a full tunnel, sending all traffic through the connector. The connector would then need NAT to the internet. I didn't test this live because this connector has no internet path of its own.

## Troubleshooting scenarios

For each break, I looked for where the packets stop before deciding on a cause.

### Wrong public key

I replaced the client's public key on the connector with a random one using `wg set`.

The ping failed. tcpdump showed 148-byte handshake initiations every few seconds with no 92-byte response. In `wg show`, the peer had no endpoint, no handshake and no transfer, because the connector never accepted a single packet from it. Comparing the public keys on both sides showed the mismatch.

![Wrong key](screenshots/07-break-wrong-key.png)

The fix was reloading the config without taking the interface down, so other peers would stay connected:

```bash
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'
```

![Wrong key fixed](screenshots/07b-fix-wrong-key.png)

### Blocked port

```bash
sudo iptables -I INPUT -p udp --dport 51820 -j DROP
```

tcpdump looked almost identical to the wrong-key case: packets arriving and nothing going out. tcpdump captures before the firewall, so it can't tell the two apart. The DROP rule's packet counter went from 1 to 35, which proved it was the firewall.

![Port blocked](screenshots/08-break-port-blocked.png)

I removed the rule by its spec rather than its line number, since line numbers shift when other rules change.

```bash
sudo iptables -D INPUT -p udp --dport 51820 -j DROP
```

![Port fixed](screenshots/08b-fix-port-blocked.png)

On a cloud VM, a security group blocks traffic before it reaches the server, so tcpdump would show nothing at all. Empty tcpdump points to a cloud firewall or routing problem. Packets in with no reply points to the host firewall or keys.

### Client AllowedIPs missing the private subnet

I removed 10.20.0.0/24 from the client's AllowedIPs. The user's view: the VPN is connected and the gateway answers pings, but the app won't load.

The handshake was fresh, but tcpdump on the connector captured 0 packets, and `Find-NetRoute` showed 10.20.0.2 going out via Wi-Fi. The request never entered the tunnel.

![AllowedIPs break](screenshots/09-break-allowedips.png)

Adding the subnet back fixed it:

![AllowedIPs fixed](screenshots/09b-fix-allowedips.png)

### IP forwarding off

This one happened naturally on the first attempt to reach the app. Ubuntu has `net.ipv4.ip_forward = 0` by default, so the connector acted as a host, not a router.

tcpdump showed TCP SYNs arriving on `wg0 In`, retransmitted with the same sequence number, and nothing on `veth-conn Out`. The packets reached the connector and stopped there.

![IP forwarding off](screenshots/10-break-ip-forwarding.png)

```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

Screenshot 04 shows the result after this fix. `sysctl -w` doesn't survive a reboot. In production, the setting belongs in a file under `/etc/sysctl.d/`.

### Summary

| Symptom | Where packets stop | Cause | Evidence |
|---|---|---|---|
| No handshake | Arrive at connector, no reply | Wrong key | Peer has no endpoint or handshake, keys don't match |
| No handshake | Arrive, then dropped | Host firewall | iptables DROP counter rising |
| Handshake OK, app unreachable | Arrive on wg0, not forwarded | IP forwarding off | `wg0 In` with no `veth-conn Out` |
| Handshake OK, app unreachable | Never leave the laptop | Client AllowedIPs | Empty tcpdump, route via Wi-Fi |

## Running it again

The WireGuard config and keys persist. The namespace, the web app and the forwarding setting don't survive a WSL restart. After restarting:

```bash
ip -br addr show eth0          # the WSL IP can change, update the client Endpoint if it did
sudo wg-quick up wg0
./scripts/setup-private-network.sh
```

## What I'd add next

- Run the connector on a cloud VM, with a security group in place of iptables
- Make the connector dial out, so no inbound port is needed (how most commercial connectors work)
- Add a second client to see per-peer AllowedIPs on the connector
