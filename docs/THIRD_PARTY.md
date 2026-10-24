# Third-party components and assets

- Original VoxType source and documentation: Apache-2.0; [LICENSE](../LICENSE), [NOTICE](../NOTICE).
- Apple frameworks/SDK: external system/toolchain components. Generated interface copies stay under the excluded `.build/` directory; this project does not relicense Apple's SDK.
- System zlib: dynamically linked through the small CGZip wrapper. Upstream uses the [zlib license](https://zlib.net/zlib_license.html). No zlib source/library binary is vendored here.
- Doubao/Volcengine: hosted service, not an included open-source model. Account access, fees and terms are separate. Copied vendor reference documents stay excluded; public documentation links to the [official API page](https://docs.volcengine.com/docs/DoubaoVoice/bidirectional-streaming-automatic-speech-recognition-websocket?lang=zh).
- VoxType icon: AI-generated for this project; source and prompts in [branding notes](../Resources/Branding/README.md). No exclusivity or trademark-clearance claim is made.
- Benchmark sentences: original fictional text under this project's license. Speech generated with macOS voices stays local; only hashes/measurements are published, not generated voice assets.
- Other product names identify comparison subjects. No affiliation or endorsement is implied; descriptions link to official pages.

Document provenance and licenses here when adding dependencies, model weights, recordings or third-party art.
