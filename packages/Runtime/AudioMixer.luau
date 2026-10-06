--!strict
-- Shim: AudioMixer moved to packages/AVKit/AudioMixer.luau (same API; gains now drive bus
-- AudioFaders through AVKit/AudioGraph). Kept for NativeAudio, the inherited fixtures and
-- tests/runtime/run.luau.
return require("../AVKit/AudioMixer")
