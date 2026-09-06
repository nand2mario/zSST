# SST-1 register contract

Generated from `tools/registers/registers.json` by `make generate`.
Unknown silicon reset values are shown as `unknown`; they are not assumed zero.

| Address | Name | Access | Chips | FIFO / sync | Reset | Description |
|---:|---|:---:|---|:---:|---|---|
| `0x000` | `status` | RW | FBI | yes / no | unknown | Read FIFO/busy/retrace/swap status; write clears SST-1 PCI interrupts |
| `0x008` | `vertexAx` | WO | FBI+TREX | yes / no | unknown | Vertex A X, signed 12.4 |
| `0x00c` | `vertexAy` | WO | FBI+TREX | yes / no | unknown | Vertex A Y, signed 12.4 |
| `0x010` | `vertexBx` | WO | FBI+TREX | yes / no | unknown | Vertex B X, signed 12.4 |
| `0x014` | `vertexBy` | WO | FBI+TREX | yes / no | unknown | Vertex B Y, signed 12.4 |
| `0x018` | `vertexCx` | WO | FBI+TREX | yes / no | unknown | Vertex C X, signed 12.4 |
| `0x01c` | `vertexCy` | WO | FBI+TREX | yes / no | unknown | Vertex C Y, signed 12.4 |
| `0x020` | `startR` | WO | FBI+TREX | yes / no | unknown | Starting red, signed 12.12 |
| `0x024` | `startG` | WO | FBI+TREX | yes / no | unknown | Starting green, signed 12.12 |
| `0x028` | `startB` | WO | FBI+TREX | yes / no | unknown | Starting blue, signed 12.12 |
| `0x02c` | `startZ` | WO | FBI+TREX | yes / no | unknown | Starting Z, signed 20.12 |
| `0x030` | `startA` | WO | FBI+TREX | yes / no | unknown | Starting alpha, signed 12.12 |
| `0x034` | `startS` | WO | FBI+TREX | yes / no | unknown | Starting S/W, signed 14.18 |
| `0x038` | `startT` | WO | FBI+TREX | yes / no | unknown | Starting T/W, signed 14.18 |
| `0x03c` | `startW` | WO | FBI+TREX | yes / no | unknown | Starting 1/W, signed 2.30 |
| `0x040` | `dRdX` | WO | FBI+TREX | yes / no | unknown | Red X gradient, signed 12.12 |
| `0x044` | `dGdX` | WO | FBI+TREX | yes / no | unknown | Green X gradient, signed 12.12 |
| `0x048` | `dBdX` | WO | FBI+TREX | yes / no | unknown | Blue X gradient, signed 12.12 |
| `0x04c` | `dZdX` | WO | FBI+TREX | yes / no | unknown | Z X gradient, signed 20.12 |
| `0x050` | `dAdX` | WO | FBI+TREX | yes / no | unknown | Alpha X gradient, signed 12.12 |
| `0x054` | `dSdX` | WO | FBI+TREX | yes / no | unknown | S/W X gradient, signed 14.18 |
| `0x058` | `dTdX` | WO | FBI+TREX | yes / no | unknown | T/W X gradient, signed 14.18 |
| `0x05c` | `dWdX` | WO | FBI+TREX | yes / no | unknown | 1/W X gradient, signed 2.30 |
| `0x060` | `dRdY` | WO | FBI+TREX | yes / no | unknown | Red Y gradient, signed 12.12 |
| `0x064` | `dGdY` | WO | FBI+TREX | yes / no | unknown | Green Y gradient, signed 12.12 |
| `0x068` | `dBdY` | WO | FBI+TREX | yes / no | unknown | Blue Y gradient, signed 12.12 |
| `0x06c` | `dZdY` | WO | FBI+TREX | yes / no | unknown | Z Y gradient, signed 20.12 |
| `0x070` | `dAdY` | WO | FBI+TREX | yes / no | unknown | Alpha Y gradient, signed 12.12 |
| `0x074` | `dSdY` | WO | FBI+TREX | yes / no | unknown | S/W Y gradient, signed 14.18 |
| `0x078` | `dTdY` | WO | FBI+TREX | yes / no | unknown | T/W Y gradient, signed 14.18 |
| `0x07c` | `dWdY` | WO | FBI+TREX | yes / no | unknown | 1/W Y gradient, signed 2.30 |
| `0x080` | `triangleCMD` | WO | FBI+TREX | yes / no | unknown | Execute fixed-point triangle |
| `0x088` | `fvertexAx` | WO | FBI+TREX | yes / no | unknown | Vertex A X, IEEE-754 alias |
| `0x08c` | `fvertexAy` | WO | FBI+TREX | yes / no | unknown | Vertex A Y, IEEE-754 alias |
| `0x090` | `fvertexBx` | WO | FBI+TREX | yes / no | unknown | Vertex B X, IEEE-754 alias |
| `0x094` | `fvertexBy` | WO | FBI+TREX | yes / no | unknown | Vertex B Y, IEEE-754 alias |
| `0x098` | `fvertexCx` | WO | FBI+TREX | yes / no | unknown | Vertex C X, IEEE-754 alias |
| `0x09c` | `fvertexCy` | WO | FBI+TREX | yes / no | unknown | Vertex C Y, IEEE-754 alias |
| `0x0a0` | `fstartR` | WO | FBI+TREX | yes / no | unknown | Starting red, IEEE-754 alias |
| `0x0a4` | `fstartG` | WO | FBI+TREX | yes / no | unknown | Starting green, IEEE-754 alias |
| `0x0a8` | `fstartB` | WO | FBI+TREX | yes / no | unknown | Starting blue, IEEE-754 alias |
| `0x0ac` | `fstartZ` | WO | FBI+TREX | yes / no | unknown | Starting Z, IEEE-754 alias |
| `0x0b0` | `fstartA` | WO | FBI+TREX | yes / no | unknown | Starting alpha, IEEE-754 alias |
| `0x0b4` | `fstartS` | WO | FBI+TREX | yes / no | unknown | Starting S/W, IEEE-754 alias |
| `0x0b8` | `fstartT` | WO | FBI+TREX | yes / no | unknown | Starting T/W, IEEE-754 alias |
| `0x0bc` | `fstartW` | WO | FBI+TREX | yes / no | unknown | Starting 1/W, IEEE-754 alias |
| `0x0c0` | `fdRdX` | WO | FBI+TREX | yes / no | unknown | Red X gradient, IEEE-754 alias |
| `0x0c4` | `fdGdX` | WO | FBI+TREX | yes / no | unknown | Green X gradient, IEEE-754 alias |
| `0x0c8` | `fdBdX` | WO | FBI+TREX | yes / no | unknown | Blue X gradient, IEEE-754 alias |
| `0x0cc` | `fdZdX` | WO | FBI+TREX | yes / no | unknown | Z X gradient, IEEE-754 alias |
| `0x0d0` | `fdAdX` | WO | FBI+TREX | yes / no | unknown | Alpha X gradient, IEEE-754 alias |
| `0x0d4` | `fdSdX` | WO | FBI+TREX | yes / no | unknown | S/W X gradient, IEEE-754 alias |
| `0x0d8` | `fdTdX` | WO | FBI+TREX | yes / no | unknown | T/W X gradient, IEEE-754 alias |
| `0x0dc` | `fdWdX` | WO | FBI+TREX | yes / no | unknown | 1/W X gradient, IEEE-754 alias |
| `0x0e0` | `fdRdY` | WO | FBI+TREX | yes / no | unknown | Red Y gradient, IEEE-754 alias |
| `0x0e4` | `fdGdY` | WO | FBI+TREX | yes / no | unknown | Green Y gradient, IEEE-754 alias |
| `0x0e8` | `fdBdY` | WO | FBI+TREX | yes / no | unknown | Blue Y gradient, IEEE-754 alias |
| `0x0ec` | `fdZdY` | WO | FBI+TREX | yes / no | unknown | Z Y gradient, IEEE-754 alias |
| `0x0f0` | `fdAdY` | WO | FBI+TREX | yes / no | unknown | Alpha Y gradient, IEEE-754 alias |
| `0x0f4` | `fdSdY` | WO | FBI+TREX | yes / no | unknown | S/W Y gradient, IEEE-754 alias |
| `0x0f8` | `fdTdY` | WO | FBI+TREX | yes / no | unknown | T/W Y gradient, IEEE-754 alias |
| `0x0fc` | `fdWdY` | WO | FBI+TREX | yes / no | unknown | 1/W Y gradient, IEEE-754 alias |
| `0x100` | `ftriangleCMD` | WO | FBI+TREX | yes / no | unknown | Execute floating-point triangle |
| `0x104` | `fbzColorPath` | RW | FBI+TREX | yes / no | unknown | Color/alpha combine and texture enable |
| `0x108` | `fogMode` | RW | FBI | yes / no | unknown | Fog mode |
| `0x10c` | `alphaMode` | RW | FBI | yes / no | unknown | Alpha test and blend control |
| `0x110` | `fbzMode` | RW | FBI | yes / yes | unknown | Framebuffer, clipping, depth and write control |
| `0x114` | `lfbMode` | RW | FBI | yes / yes | unknown | Linear framebuffer format, buffer and pipeline control |
| `0x118` | `clipLeftRight` | RW | FBI | yes / yes | unknown | Inclusive left and exclusive right clip coordinates |
| `0x11c` | `clipLowYHighY` | RW | FBI | yes / yes | unknown | Inclusive low-Y and exclusive high-Y clip coordinates |
| `0x120` | `nopCMD` | WO | FBI+TREX | yes / yes | unknown | Execute NOP/fence and optional counter reset |
| `0x124` | `fastfillCMD` | WO | FBI | yes / yes | unknown | Execute fast rectangle fill |
| `0x128` | `swapbufferCMD` | WO | FBI | yes / yes | unknown | Queue a display-buffer swap |
| `0x12c` | `fogColor` | RW | FBI | yes / yes | unknown | Constant RGB888 fog color |
| `0x130` | `zaColor` | RW | FBI | yes / yes | unknown | Constant alpha and depth value |
| `0x134` | `chromaKey` | RW | FBI | yes / yes | unknown | RGB888 chroma-key value |
| `0x140` | `stipple` | RW | FBI | yes / yes | unknown | Rotating or pattern stipple value |
| `0x144` | `color0` | RW | FBI | yes / yes | unknown | ARGB8888 constant color zero |
| `0x148` | `color1` | RW | FBI | yes / yes | unknown | ARGB8888 constant color one / fast-fill color |
| `0x14c` | `fbiPixelsIn` | RO | FBI | yes / yes | unknown | Pixels entering FBI |
| `0x150` | `fbiChromaFail` | RO | FBI | yes / yes | unknown | Pixels rejected by chroma test |
| `0x154` | `fbiZfuncFail` | RO | FBI | yes / yes | unknown | Pixels rejected by depth test |
| `0x158` | `fbiAfuncFail` | RO | FBI | yes / yes | unknown | Pixels rejected by alpha test |
| `0x15c` | `fbiPixelsOut` | RO | FBI | yes / yes | unknown | Pixels written by FBI |
| `0x160` | `fogTable00` | WO | FBI | yes / yes | unknown | Fog table word 0 |
| `0x164` | `fogTable01` | WO | FBI | yes / yes | unknown | Fog table word 1 |
| `0x168` | `fogTable02` | WO | FBI | yes / yes | unknown | Fog table word 2 |
| `0x16c` | `fogTable03` | WO | FBI | yes / yes | unknown | Fog table word 3 |
| `0x170` | `fogTable04` | WO | FBI | yes / yes | unknown | Fog table word 4 |
| `0x174` | `fogTable05` | WO | FBI | yes / yes | unknown | Fog table word 5 |
| `0x178` | `fogTable06` | WO | FBI | yes / yes | unknown | Fog table word 6 |
| `0x17c` | `fogTable07` | WO | FBI | yes / yes | unknown | Fog table word 7 |
| `0x180` | `fogTable08` | WO | FBI | yes / yes | unknown | Fog table word 8 |
| `0x184` | `fogTable09` | WO | FBI | yes / yes | unknown | Fog table word 9 |
| `0x188` | `fogTable10` | WO | FBI | yes / yes | unknown | Fog table word 10 |
| `0x18c` | `fogTable11` | WO | FBI | yes / yes | unknown | Fog table word 11 |
| `0x190` | `fogTable12` | WO | FBI | yes / yes | unknown | Fog table word 12 |
| `0x194` | `fogTable13` | WO | FBI | yes / yes | unknown | Fog table word 13 |
| `0x198` | `fogTable14` | WO | FBI | yes / yes | unknown | Fog table word 14 |
| `0x19c` | `fogTable15` | WO | FBI | yes / yes | unknown | Fog table word 15 |
| `0x1a0` | `fogTable16` | WO | FBI | yes / yes | unknown | Fog table word 16 |
| `0x1a4` | `fogTable17` | WO | FBI | yes / yes | unknown | Fog table word 17 |
| `0x1a8` | `fogTable18` | WO | FBI | yes / yes | unknown | Fog table word 18 |
| `0x1ac` | `fogTable19` | WO | FBI | yes / yes | unknown | Fog table word 19 |
| `0x1b0` | `fogTable20` | WO | FBI | yes / yes | unknown | Fog table word 20 |
| `0x1b4` | `fogTable21` | WO | FBI | yes / yes | unknown | Fog table word 21 |
| `0x1b8` | `fogTable22` | WO | FBI | yes / yes | unknown | Fog table word 22 |
| `0x1bc` | `fogTable23` | WO | FBI | yes / yes | unknown | Fog table word 23 |
| `0x1c0` | `fogTable24` | WO | FBI | yes / yes | unknown | Fog table word 24 |
| `0x1c4` | `fogTable25` | WO | FBI | yes / yes | unknown | Fog table word 25 |
| `0x1c8` | `fogTable26` | WO | FBI | yes / yes | unknown | Fog table word 26 |
| `0x1cc` | `fogTable27` | WO | FBI | yes / yes | unknown | Fog table word 27 |
| `0x1d0` | `fogTable28` | WO | FBI | yes / yes | unknown | Fog table word 28 |
| `0x1d4` | `fogTable29` | WO | FBI | yes / yes | unknown | Fog table word 29 |
| `0x1d8` | `fogTable30` | WO | FBI | yes / yes | unknown | Fog table word 30 |
| `0x1dc` | `fogTable31` | WO | FBI | yes / yes | unknown | Fog table word 31 |
| `0x200` | `fbiInit4` | RW | FBI | no / no | unknown | FBI hardware initialization 4 |
| `0x204` | `vRetrace` | RO | FBI | no / no | unknown | Vertical retrace counter |
| `0x208` | `backPorch` | RW | FBI | no / no | unknown | Video back-porch timing |
| `0x20c` | `videoDimensions` | RW | FBI | no / no | unknown | Native video dimensions |
| `0x210` | `fbiInit0` | RW | FBI | no / no | unknown | FBI hardware initialization 0 |
| `0x214` | `fbiInit1` | RW | FBI | no / no | unknown | FBI hardware initialization 1 |
| `0x218` | `fbiInit2` | RW | FBI | no / no | unknown | FBI hardware initialization 2 |
| `0x21c` | `fbiInit3` | RW | FBI | no / no | unknown | FBI hardware initialization 3 |
| `0x220` | `hSync` | WO | FBI | no / no | unknown | Horizontal sync timing |
| `0x224` | `vSync` | WO | FBI | no / no | unknown | Vertical sync timing |
| `0x228` | `clutData` | WO | FBI | no / no | unknown | Color lookup table write |
| `0x22c` | `dacData` | WO | FBI | no / no | unknown | External DAC access |
| `0x230` | `maxRgbDelta` | WO | FBI | no / no | unknown | Video-filter RGB threshold |
| `0x300` | `textureMode` | WO | TREX | yes / no | unknown | Texture format, filtering and combine |
| `0x304` | `tLOD` | WO | TREX | yes / no | unknown | Texture LOD, aspect and download control |
| `0x308` | `tDetail` | WO | TREX | yes / no | unknown | Texture detail bias and scale |
| `0x30c` | `texBaseAddr` | WO | TREX | yes / no | unknown | Texture base address |
| `0x310` | `texBaseAddr1` | WO | TREX | yes / no | unknown | Supplemental LOD 1 base |
| `0x314` | `texBaseAddr2` | WO | TREX | yes / no | unknown | Supplemental LOD 2 base |
| `0x318` | `texBaseAddr38` | WO | TREX | yes / no | unknown | Supplemental LOD 3-8 base |
| `0x31c` | `trexInit0` | WO | TREX | yes / no | unknown | TREX hardware initialization 0 |
| `0x320` | `trexInit1` | WO | TREX | yes / no | unknown | TREX hardware initialization 1 |
| `0x324` | `nccTable0_00` | WO | TREX | yes / yes | unknown | NCC table 0 word 0 |
| `0x328` | `nccTable0_01` | WO | TREX | yes / yes | unknown | NCC table 0 word 1 |
| `0x32c` | `nccTable0_02` | WO | TREX | yes / yes | unknown | NCC table 0 word 2 |
| `0x330` | `nccTable0_03` | WO | TREX | yes / yes | unknown | NCC table 0 word 3 |
| `0x334` | `nccTable0_04` | WO | TREX | yes / yes | unknown | NCC table 0 word 4 |
| `0x338` | `nccTable0_05` | WO | TREX | yes / yes | unknown | NCC table 0 word 5 |
| `0x33c` | `nccTable0_06` | WO | TREX | yes / yes | unknown | NCC table 0 word 6 |
| `0x340` | `nccTable0_07` | WO | TREX | yes / yes | unknown | NCC table 0 word 7 |
| `0x344` | `nccTable0_08` | WO | TREX | yes / yes | unknown | NCC table 0 word 8 |
| `0x348` | `nccTable0_09` | WO | TREX | yes / yes | unknown | NCC table 0 word 9 |
| `0x34c` | `nccTable0_10` | WO | TREX | yes / yes | unknown | NCC table 0 word 10 |
| `0x350` | `nccTable0_11` | WO | TREX | yes / yes | unknown | NCC table 0 word 11 |
| `0x354` | `nccTable1_00` | WO | TREX | yes / yes | unknown | NCC table 1 word 0 |
| `0x358` | `nccTable1_01` | WO | TREX | yes / yes | unknown | NCC table 1 word 1 |
| `0x35c` | `nccTable1_02` | WO | TREX | yes / yes | unknown | NCC table 1 word 2 |
| `0x360` | `nccTable1_03` | WO | TREX | yes / yes | unknown | NCC table 1 word 3 |
| `0x364` | `nccTable1_04` | WO | TREX | yes / yes | unknown | NCC table 1 word 4 |
| `0x368` | `nccTable1_05` | WO | TREX | yes / yes | unknown | NCC table 1 word 5 |
| `0x36c` | `nccTable1_06` | WO | TREX | yes / yes | unknown | NCC table 1 word 6 |
| `0x370` | `nccTable1_07` | WO | TREX | yes / yes | unknown | NCC table 1 word 7 |
| `0x374` | `nccTable1_08` | WO | TREX | yes / yes | unknown | NCC table 1 word 8 |
| `0x378` | `nccTable1_09` | WO | TREX | yes / yes | unknown | NCC table 1 word 9 |
| `0x37c` | `nccTable1_10` | WO | TREX | yes / yes | unknown | NCC table 1 word 10 |
| `0x380` | `nccTable1_11` | WO | TREX | yes / yes | unknown | NCC table 1 word 11 |

## Alternate triangle map

When `fbiInit3[0]` and PCI address bit 21 are set, these low offsets map to the canonical registers below.

| BAR address | Alias | Canonical register |
|---:|---|---|
| `0x200000` | `alt_status` | `status` |
| `0x200008` | `alt_vertexAx` | `vertexAx` |
| `0x20000c` | `alt_vertexAy` | `vertexAy` |
| `0x200010` | `alt_vertexBx` | `vertexBx` |
| `0x200014` | `alt_vertexBy` | `vertexBy` |
| `0x200018` | `alt_vertexCx` | `vertexCx` |
| `0x20001c` | `alt_vertexCy` | `vertexCy` |
| `0x200020` | `alt_startR` | `startR` |
| `0x200024` | `alt_dRdX` | `dRdX` |
| `0x200028` | `alt_dRdY` | `dRdY` |
| `0x20002c` | `alt_startG` | `startG` |
| `0x200030` | `alt_dGdX` | `dGdX` |
| `0x200034` | `alt_dGdY` | `dGdY` |
| `0x200038` | `alt_startB` | `startB` |
| `0x20003c` | `alt_dBdX` | `dBdX` |
| `0x200040` | `alt_dBdY` | `dBdY` |
| `0x200044` | `alt_startZ` | `startZ` |
| `0x200048` | `alt_dZdX` | `dZdX` |
| `0x20004c` | `alt_dZdY` | `dZdY` |
| `0x200050` | `alt_startA` | `startA` |
| `0x200054` | `alt_dAdX` | `dAdX` |
| `0x200058` | `alt_dAdY` | `dAdY` |
| `0x20005c` | `alt_startS` | `startS` |
| `0x200060` | `alt_dSdX` | `dSdX` |
| `0x200064` | `alt_dSdY` | `dSdY` |
| `0x200068` | `alt_startT` | `startT` |
| `0x20006c` | `alt_dTdX` | `dTdX` |
| `0x200070` | `alt_dTdY` | `dTdY` |
| `0x200074` | `alt_startW` | `startW` |
| `0x200078` | `alt_dWdX` | `dWdX` |
| `0x20007c` | `alt_dWdY` | `dWdY` |
| `0x200080` | `alt_triangleCMD` | `triangleCMD` |
| `0x200088` | `alt_fvertexAx` | `fvertexAx` |
| `0x20008c` | `alt_fvertexAy` | `fvertexAy` |
| `0x200090` | `alt_fvertexBx` | `fvertexBx` |
| `0x200094` | `alt_fvertexBy` | `fvertexBy` |
| `0x200098` | `alt_fvertexCx` | `fvertexCx` |
| `0x20009c` | `alt_fvertexCy` | `fvertexCy` |
| `0x2000a0` | `alt_fstartR` | `fstartR` |
| `0x2000a4` | `alt_fdRdX` | `fdRdX` |
| `0x2000a8` | `alt_fdRdY` | `fdRdY` |
| `0x2000ac` | `alt_fstartG` | `fstartG` |
| `0x2000b0` | `alt_fdGdX` | `fdGdX` |
| `0x2000b4` | `alt_fdGdY` | `fdGdY` |
| `0x2000b8` | `alt_fstartB` | `fstartB` |
| `0x2000bc` | `alt_fdBdX` | `fdBdX` |
| `0x2000c0` | `alt_fdBdY` | `fdBdY` |
| `0x2000c4` | `alt_fstartZ` | `fstartZ` |
| `0x2000c8` | `alt_fdZdX` | `fdZdX` |
| `0x2000cc` | `alt_fdZdY` | `fdZdY` |
| `0x2000d0` | `alt_fstartA` | `fstartA` |
| `0x2000d4` | `alt_fdAdX` | `fdAdX` |
| `0x2000d8` | `alt_fdAdY` | `fdAdY` |
| `0x2000dc` | `alt_fstartS` | `fstartS` |
| `0x2000e0` | `alt_fdSdX` | `fdSdX` |
| `0x2000e4` | `alt_fdSdY` | `fdSdY` |
| `0x2000e8` | `alt_fstartT` | `fstartT` |
| `0x2000ec` | `alt_fdTdX` | `fdTdX` |
| `0x2000f0` | `alt_fdTdY` | `fdTdY` |
| `0x2000f4` | `alt_fstartW` | `fstartW` |
| `0x2000f8` | `alt_fdWdX` | `fdWdX` |
| `0x2000fc` | `alt_fdWdY` | `fdWdY` |
| `0x200100` | `alt_ftriangleCMD` | `ftriangleCMD` |

## Sources

- SST-1 specification 1.61, section 5 register tables
- SST-1 sst.h, Sstregs and SST_* field definitions
- SpinalVoodoo-repro/emu/86Box/src/include/86box/vid_voodoo_regs.h at pinned 86Box commit
