# Native document preview

`DocumentCaptureApple` owns camera authorization, the serial AVFoundation session,
acquisition and observation delivery. `DocumentCapturePreview` renders the supplied
preview and framing guide. The host owns navigation, localized copy and explicit start,
stop and cancellation. Visibility alone does not authorize a capture ceremony.

The copied Apple AVCam implementation notice remains in
`../ThirdPartyNotices/Apple-AVCam.txt`. Apple platform APIs supply the preview layer;
preview geometry does not establish document authenticity or camera calibration.

Compile both iOS lanes and test lifecycle settlement separately. Simulator compilation
and synthetic tests do not qualify a real front/back capture or VoiceOver interaction.
