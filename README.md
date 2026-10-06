# Skips

A one-button skipping-rope roguelike on Roblox. Jump the rope as it speeds up, pick upgrade cards between rounds and see how long you last. It's inspired by Scarlet Skips by Yerk Games.

**[Play Skips on Roblox](https://www.roblox.com/games/112696688372678)**

I took it from idea to a published game in one week, in September 2026.

## What's in it

- Solo runs with upgrade cards, three offered at a time from a set of ten
- Matches against other players and bots, with Elo ratings and leaderboards
- Tickets that pay for revives, plus cosmetics and redeemable codes
- Avatars normalized to one size, so every run looks the same on screen

## How it's built

- About 19,600 lines of Luau in client, server and shared modules, synced into Roblox Studio with Rojo.
- The run is a deterministic simulation, not Roblox physics. The same module runs on the client for responsiveness and on the server for authority, so the server's result is the one that counts.
- A seeded random number generator makes a run with the same seed play out exactly the same.
- The tests in `tests/` drive the real simulation module.

## Running it

Install Rojo, run `rojo serve`, and connect the Rojo plugin in Roblox Studio. The map and art live in the Roblox place file, which isn't in this repo.

Built solo by Sean Aminov, with AI coding assistants helping along the way.
