//! Audio output on macOS through the default-output AudioUnit (AudioToolbox).
//!
//! The AudioUnit pulls interleaved f32 frames from a `playback.Engine` on its
//! own real-time thread. We hand it the song's native sample rate and channel
//! count; the default output unit converts to whatever the device uses.

const std = @import("std");
const playback = @import("playback.zig");

const OSStatus = i32;
const AudioUnit = *opaque {};
const AudioComponent = *opaque {};

const AudioComponentDescription = extern struct {
    componentType: u32,
    componentSubType: u32,
    componentManufacturer: u32,
    componentFlags: u32 = 0,
    componentFlagsMask: u32 = 0,
};

const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

const AudioBufferList = extern struct {
    mNumberBuffers: u32,
    mBuffers: [1]AudioBuffer,
};

const AURenderCallback = *const fn (
    ref: ?*anyopaque,
    flags: *u32,
    timestamp: *const anyopaque,
    bus: u32,
    frames: u32,
    data: ?*AudioBufferList,
) callconv(.c) OSStatus;

const AURenderCallbackStruct = extern struct {
    inputProc: AURenderCallback,
    inputProcRefCon: ?*anyopaque,
};

extern "c" fn AudioComponentFindNext(component: ?AudioComponent, desc: *const AudioComponentDescription) ?AudioComponent;
extern "c" fn AudioComponentInstanceNew(component: AudioComponent, out: *?AudioUnit) OSStatus;
extern "c" fn AudioComponentInstanceDispose(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitSetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: *const anyopaque, size: u32) OSStatus;
extern "c" fn AudioUnitInitialize(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitUninitialize(unit: AudioUnit) OSStatus;
extern "c" fn AudioOutputUnitStart(unit: AudioUnit) OSStatus;
extern "c" fn AudioOutputUnitStop(unit: AudioUnit) OSStatus;

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

const kAudioUnitType_Output = fourcc("auou");
const kAudioUnitSubType_DefaultOutput = fourcc("def ");
const kAudioUnitManufacturer_Apple = fourcc("appl");
const kAudioUnitProperty_StreamFormat = 8;
const kAudioUnitProperty_SetRenderCallback = 23;
const kAudioUnitScope_Input = 1;
const kAudioFormatLinearPCM = fourcc("lpcm");
const kAudioFormatFlagIsFloat = 1 << 0;
const kAudioFormatFlagIsPacked = 1 << 3;

pub const Error = error{AudioOutputUnavailable};

pub const Output = struct {
    unit: AudioUnit,

    /// Opens the default output device and starts pulling from `engine`.
    /// `engine` must outlive the returned `Output` (call `deinit` first).
    pub fn start(engine: *playback.Engine) Error!Output {
        const desc: AudioComponentDescription = .{
            .componentType = kAudioUnitType_Output,
            .componentSubType = kAudioUnitSubType_DefaultOutput,
            .componentManufacturer = kAudioUnitManufacturer_Apple,
        };
        const component = AudioComponentFindNext(null, &desc) orelse return error.AudioOutputUnavailable;
        var unit_opt: ?AudioUnit = null;
        try check(AudioComponentInstanceNew(component, &unit_opt));
        const unit = unit_opt orelse return error.AudioOutputUnavailable;
        errdefer _ = AudioComponentInstanceDispose(unit);

        const bytes_per_frame: u32 = @sizeOf(f32) * @as(u32, engine.channels);
        const format: AudioStreamBasicDescription = .{
            .mSampleRate = @floatFromInt(engine.sample_rate),
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = bytes_per_frame,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = bytes_per_frame,
            .mChannelsPerFrame = engine.channels,
            .mBitsPerChannel = 32,
        };
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, @sizeOf(AudioStreamBasicDescription)));

        const callback: AURenderCallbackStruct = .{ .inputProc = renderCallback, .inputProcRefCon = engine };
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, @sizeOf(AURenderCallbackStruct)));

        try check(AudioUnitInitialize(unit));
        errdefer _ = AudioUnitUninitialize(unit);
        try check(AudioOutputUnitStart(unit));
        return .{ .unit = unit };
    }

    /// Stops the device. After this returns the engine is no longer read.
    pub fn deinit(self: Output) void {
        _ = AudioOutputUnitStop(self.unit);
        _ = AudioUnitUninitialize(self.unit);
        _ = AudioComponentInstanceDispose(self.unit);
    }
};

fn check(status: OSStatus) Error!void {
    if (status != 0) return error.AudioOutputUnavailable;
}

fn renderCallback(ref: ?*anyopaque, flags: *u32, timestamp: *const anyopaque, bus: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus {
    _ = flags;
    _ = timestamp;
    _ = bus;
    const engine: *playback.Engine = @ptrCast(@alignCast(ref.?));
    const list = data orelse return 0;
    // Interleaved format: a single buffer holding every channel.
    const buf = &list.mBuffers[0];
    const ptr: [*]f32 = @ptrCast(@alignCast(buf.mData orelse return 0));
    const len = @min(@as(usize, frames) * engine.channels, buf.mDataByteSize / @sizeOf(f32));
    engine.render(ptr[0..len]);
    return 0;
}
