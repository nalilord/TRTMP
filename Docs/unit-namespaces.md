# Unit Namespaces

## Policy

`TRTMP` remains the library identity even as the project grows beyond RTMP.
Protocol implementations occupy the second namespace component:

```text
TRTMP.RTMP.*
TRTMP.RTP.*
TRTMP.RTSP.*
TRTMP.WebRTC.*
```

Only infrastructure that is genuinely usable by several protocols belongs
outside those protocol branches. Current shared groups are `TRTMP.Core.*`,
`TRTMP.Transport.*` (including `TRTMP.Transport.TLS`), and `TRTMP.FFmpeg.*`.

Unit files remain directly under `Source/` using their complete dotted unit
name. Delphi and FPC can therefore resolve the entire library through one
source search path without recursive or compiler-specific configuration.

New units should follow these rules:

- use `TRTMP.<Protocol>.<Subsystem>.<Purpose>` for protocol-specific code;
- do not repeat `Rtmp` after the `TRTMP.RTMP` prefix;
- promote a unit into a shared namespace only after it has a protocol-neutral
  API and at least two realistic consumers;
- keep optional native-library integrations under their integration namespace;
- avoid creating a new subsystem for a single private helper.

Examples of future names:

```pascal
TRTMP.RTP.Packet
TRTMP.RTSP.Client
TRTMP.RTSP.Protocol.Message
TRTMP.WebRTC.PeerConnection
TRTMP.WebRTC.Signaling
```

## RTMP Migration Map

| Previous unit | Namespaced unit |
|---|---|
| `RtmpCompat` | `TRTMP.Core.Compat` |
| `RtmpTypes` | `TRTMP.RTMP.Types` |
| `RtmpBytes` | `TRTMP.Core.Bytes` |
| `RtmpLog` | `TRTMP.RTMP.Log` |
| `RtmpTransport` | `TRTMP.Transport` |
| `RtmpTransportNative` | `TRTMP.Transport.Native` |
| `RtmpFFmpeg` | `TRTMP.FFmpeg` |
| `RtmpFFmpegApi` | `TRTMP.FFmpeg.API` |
| `RtmpFrameConvertFFmpeg` | `TRTMP.FFmpeg.FrameConvert` |
| `RtmpProtocol` | `TRTMP.RTMP.Protocol.Core` |
| `RtmpChunkReassembler` | `TRTMP.RTMP.Protocol.Chunk` |
| `RtmpAmf0` | `TRTMP.RTMP.Protocol.AMF0` |
| `RtmpCommand` | `TRTMP.RTMP.Protocol.Command` |
| `RtmpFlv` | `TRTMP.RTMP.Protocol.FLV` |
| `RtmpPacket` | `TRTMP.RTMP.Media.Packet` |
| `RtmpBuffer` | `TRTMP.RTMP.Media.Buffer` |
| `RtmpAnalyzer` | `TRTMP.RTMP.Media.Analyzer` |
| `RtmpStats` | `TRTMP.RTMP.Media.Stats` |
| `RtmpServer` | `TRTMP.RTMP.Server` |
| `RtmpServerSession` | `TRTMP.RTMP.Server.Session` |
| `RtmpClient` | `TRTMP.RTMP.Client` |
| `RtmpPipeline` | `TRTMP.RTMP.Pipeline` |
| `RtmpMediaPipeline` | `TRTMP.RTMP.Pipeline.Media` |
| `RtmpLiveSourceSwitcher` | `TRTMP.RTMP.Pipeline.Switcher` |
| `RtmpDecoder` | `TRTMP.RTMP.Decode` |
| `RtmpDecoderFFmpeg` | `TRTMP.RTMP.Decode.FFmpeg` |
| `RtmpPreview` | `TRTMP.RTMP.Preview` |
| `RtmpPreviewHardwareFrame` | `TRTMP.RTMP.Preview.HardwareFrame` |
| `RtmpPreviewSfml` | `TRTMP.RTMP.Preview.SFML` |

New protocol-specific units, such as `TRTMP.RTMP.Auth`, have no legacy mapping.

This is a pre-release breaking rename. Applications should update their `uses`
clauses to the namespaced units. Legacy duplicates are intentionally not kept,
because that would leave two competing public naming schemes before the first
stable release.

`Tools/check-unit-names.sh` verifies that every source filename matches its
dotted unit declaration and that every library unit uses the `TRTMP` root.
