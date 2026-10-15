#!/usr/bin/env bash
# Rebuilds the "private" network namespace and test web app.
# Run on the connector after: sudo wg-quick up wg0
set -euo pipefail

sudo ip netns add private
sudo ip link add veth-conn type veth peer name veth-priv
sudo ip link set veth-priv netns private

sudo ip addr add 10.20.0.1/24 dev veth-conn
sudo ip link set veth-conn up

sudo ip netns exec private ip addr add 10.20.0.2/24 dev veth-priv
sudo ip netns exec private ip link set veth-priv up
sudo ip netns exec private ip link set lo up
sudo ip netns exec private ip route add default via 10.20.0.1

sudo sysctl -w net.ipv4.ip_forward=1

mkdir -p ~/wg-lab/site
echo "<h1>Private app: reached through WireGuard</h1>" > ~/wg-lab/site/index.html
sudo ip netns exec private python3 -m http.server 8080 --directory ~/wg-lab/site > ~/wg-lab/http.log 2>&1 &
echo "Private app running at http://10.20.0.2:8080"
