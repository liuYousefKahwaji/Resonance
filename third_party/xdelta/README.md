# xdelta decoder

Unmodified core sources from https://github.com/jmacd/xdelta at
`2c36417e6d09bf700d3d1cca44ed3e42101016c3` (3.2.1), Apache-2.0; see LICENSE.
Only the decoder is embedded. Secondary compression and encoding are disabled.
Release patches use `-S none -B 16777216 -W 8388608` with the same revision.
The decoder has a 16 MiB window cap and reads source/patch files in 64 KiB blocks.

