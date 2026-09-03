# The relay

Online co-op without port forwarding. Every peer, the host included, keeps
an ENet relay connection to this server. The server exchanges public endpoint
candidates over UDP 43212 so each host-client pair can punch a lower-latency
direct path; UDP 43211 remains the seamless fallback and room-control path.
A host gets a six-character room code; friends type it in the lobby.

- `relay_frame.gd` — the one-byte route and the relay-op codec (pure).
- `relay_rooms.gd` — rooms, member ids, forwarding decisions (pure, tested
  by `tests/test_relay_rooms.gd`).
- `relay_server.gd` — the ENet shell around the rooms.
- `relay_main.gd` — the process: `godot --headless -s relay/relay_main.gd -- --port 43211 --punch-port 43212`.

## Deploy

```
relay/deploy.sh            # creates or reuses the nyc3 droplet, installs, starts
```

Needs `doctl` authenticated and an SSH key registered with DigitalOcean that
matches one in `~/.ssh`. The script prints the droplet's IP; put it in
`SessionRules.RELAY_ADDRESS` and cut a release, since the address is baked
into the game. Run it again after changing anything under `relay/`,
`scripts/net/` or `data/`: it refreshes the files and restarts the service.

## Check

From this machine, verify the fallback relay:

```
godot --headless -s res://tools/probe_relay.gd
```

After the coordinated protocol-2 relay and client deploy, verify punched star
links plus forced relay fallback (or pass `-- --address IP`):

```
godot --headless -s res://tools/probe_punch.gd
```

Use the probe's documented `--role host` / `--role client` mode across two
real networks; loopback proves wiring, not consumer-NAT traversal.

```
ssh -i ~/.ssh/digitalocean root@68.183.52.156 journalctl -u rootkit-relay -f
```

It logs `relay: listening on UDP 43211` and
`relay: punch discovery on UDP 43212` at start, then a stats line once a
minute: rooms, members, packets forwarded, refusals.
