# The relay

Online co-op without port forwarding. Every peer, the host included, dials
this server as an ENet client; the server forwards packets between the
members of a room and never decodes a game packet. A host gets a
six-character room code; friends type it in the lobby.

- `relay_frame.gd` — the one-byte route and the relay-op codec (pure).
- `relay_rooms.gd` — rooms, member ids, forwarding decisions (pure, tested
  by `tests/test_relay_rooms.gd`).
- `relay_server.gd` — the ENet shell around the rooms.
- `relay_main.gd` — the process: `godot --headless -s relay/relay_main.gd -- --port 43211`.

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

```
ssh root@<ip> journalctl -u rootkit-relay -f
```

It logs `relay: listening on UDP 43211` at start and a stats line once a
minute: rooms, members, packets forwarded, refusals.
