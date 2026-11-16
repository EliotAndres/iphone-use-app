// Screenshot + touch + hardware buttons over CoreDevice, for an agent driving
// its own phone. Each call opens a fresh service connection on the existing
// tunnel: the capture service drops its connection after a shot or two.
// iOS 27 drops HID input unless a DisplayService media stream is open, so on
// 27 every touch/button/type call brackets itself with one (see `open_gate`),
// unless the live stream (`probe_stream_start`) already holds it open.

use std::ptr::null_mut;
use std::time::Duration;

use idevice::core_device::hid::{ButtonState, IndigoHidClient, UniversalHidServiceClient};
use idevice::core_device::{
    CallInfoBlob, DisplayServiceClient, HevcDepacketizer, ImageFormat, RtpPacket, ScreenCaptureServiceClient,
    build_screen_audio_offer, build_screen_video_offer, build_start_audio_parameters, build_start_video_parameters,
    rtcp::{build_keyframe_request, is_rtcp},
};
use idevice::tcp::handle::UdpSocketHandle;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Mutex, mpsc};
use idevice::{IdeviceError, RsdService as _};

use crate::{IdeviceFfiError, core_device_proxy::AdapterHandle, ffi_err, rsd::RsdHandshakeHandle, run_sync_local};

/// Captures the main display. `jpeg` != 0 asks for JPEG instead of PNG.
/// Free `out_data` with `idevice_data_free(out_data, out_len)`.
///
/// # Safety
/// All pointers must be valid; handles must come from this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_screenshot(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    jpeg: u8,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() || out_data.is_null() || out_len.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let format = if jpeg != 0 { ImageFormat::Jpeg } else { ImageFormat::Png };
    let res = run_sync_local(async move {
        let (a, h) = unsafe { (&mut (*adapter).0, &mut (*handshake).0) };
        let mut client = ScreenCaptureServiceClient::connect_rsd(a, h).await?;
        client.take_screenshot(None, format).await
    });
    match res {
        Ok(image) => {
            let image = image.into_boxed_slice();
            unsafe {
                *out_len = image.len();
                *out_data = Box::into_raw(image) as *mut u8;
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Touch drag from (x1, y1) to (x2, y2), normalized 0..65535. Equal points = a tap,
/// held for `hold_ms` (a long press when ~800). A drag first holds still for `hold_ms`.
///
/// # Safety
/// Handles must be valid and come from this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_touch(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    x1: u16,
    y1: u16,
    x2: u16,
    y2: u16,
    hold_ms: u64,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let res = run_sync_local(async move {
        let (a, h) = unsafe { (&mut (*adapter).0, &mut (*handshake).0) };
        let gate = open_gate(a, h).await;
        let mut hid = UniversalHidServiceClient::connect_rsd(a, h).await?;
        // Stamp reports with this phone's own clock: idevice's default (wall
        // clock) gets drags through but most taps dropped.
        let ts = || Some(unsafe { libc::mach_absolute_time() });
        if (x1, y1) == (x2, y2) {
            hid.send_touchscreen(TOUCH_CONTACT, x1, y1, ts()).await?;
            tokio::time::sleep(Duration::from_millis(hold_ms.max(60))).await;
            hid.send_touchscreen(TOUCH_RELEASE, x1, y1, ts()).await?;
            hid.send_touchscreen(TOUCH_RELEASE, x1, y1, ts()).await?;
        } else {
            if hold_ms > 0 {
                hid.send_touchscreen(TOUCH_CONTACT, x1, y1, ts()).await?;
                tokio::time::sleep(Duration::from_millis(hold_ms)).await;
            }
            for i in 0..=30u32 {
                let t = i as f64 / 30.0;
                let x = (x1 as f64 + (x2 as f64 - x1 as f64) * t).round() as u16;
                let y = (y1 as f64 + (y2 as f64 - y1 as f64) * t).round() as u16;
                hid.send_touchscreen(TOUCH_CONTACT, x, y, ts()).await?;
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            hid.send_touchscreen(TOUCH_RELEASE, x2, y2, ts()).await?;
            hid.send_touchscreen(TOUCH_RELEASE, x2, y2, ts()).await?;
        }
        // dtuhidd handles reports async and the userspace TCP stack flushes
        // lazily; closing early loses the release, which turns taps into presses.
        tokio::time::sleep(Duration::from_millis(500)).await;
        close_gate(gate).await;
        Ok::<(), IdeviceError>(())
    });
    match res {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Presses a hardware button (HID usage page/code, e.g. home = 0x0C/0x40) for `hold_ms`.
///
/// # Safety
/// Handles must be valid and come from this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_button(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    usage_page: u64,
    usage_code: u64,
    hold_ms: u64,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let res = run_sync_local(async move {
        let (a, h) = unsafe { (&mut (*adapter).0, &mut (*handshake).0) };
        let gate = open_gate(a, h).await;
        let mut hid = IndigoHidClient::connect_rsd(a, h).await?;
        hid.send_button(usage_page, usage_code, ButtonState::Down).await?;
        tokio::time::sleep(Duration::from_millis(hold_ms)).await;
        hid.send_button(usage_page, usage_code, ButtonState::Up).await?;
        tokio::time::sleep(Duration::from_millis(500)).await; // flush, see probe_touch
        close_gate(gate).await;
        Ok::<(), IdeviceError>(())
    });
    match res {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Types ASCII `text` on the focused field (US layout); other characters are skipped.
///
/// # Safety
/// Handles must be valid and come from this library; `text` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_type(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    text: *const std::ffi::c_char,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() || text.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let Ok(text) = unsafe { std::ffi::CStr::from_ptr(text) }.to_str() else {
        return ffi_err!(IdeviceError::FfiInvalidString);
    };
    let res = run_sync_local(async move {
        let (a, h) = unsafe { (&mut (*adapter).0, &mut (*handshake).0) };
        let gate = open_gate(a, h).await;
        let mut hid = IndigoHidClient::connect_rsd(a, h).await?;
        for (usage, shift) in text.chars().filter_map(ascii_to_usage) {
            if shift {
                hid.send_keyboard(LEFT_SHIFT, ButtonState::Down).await?;
            }
            hid.send_keyboard(usage, ButtonState::Down).await?;
            hid.send_keyboard(usage, ButtonState::Up).await?;
            if shift {
                hid.send_keyboard(LEFT_SHIFT, ButtonState::Up).await?;
            }
            tokio::time::sleep(Duration::from_millis(12)).await;
        }
        tokio::time::sleep(Duration::from_millis(500)).await; // flush, see probe_touch
        close_gate(gate).await;
        Ok::<(), IdeviceError>(())
    });
    match res {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

const LEFT_SHIFT: u64 = 0xE1;
const TOUCH_CONTACT: u8 = 0xC2;
const TOUCH_RELEASE: u8 = 0x02;

/// ASCII -> (HID keyboard usage, needs shift), US layout. From tools/src/hid.rs.
fn ascii_to_usage(c: char) -> Option<(u64, bool)> {
    const SHIFTED_DIGITS: &str = "!@#$%^&*()";
    const PUNCT: &[(char, char, u64)] = &[
        ('-', '_', 0x2D), ('=', '+', 0x2E), ('[', '{', 0x2F), (']', '}', 0x30),
        ('\\', '|', 0x31), (';', ':', 0x33), ('\'', '"', 0x34), ('`', '~', 0x35),
        (',', '<', 0x36), ('.', '>', 0x37), ('/', '?', 0x38),
    ];
    Some(match c {
        'a'..='z' => (0x04 + (c as u64 - 'a' as u64), false),
        'A'..='Z' => (0x04 + (c as u64 - 'A' as u64), true),
        '1'..='9' => (0x1E + (c as u64 - '1' as u64), false),
        '0' => (0x27, false),
        '\n' => (0x28, false),
        '\t' => (0x2B, false),
        ' ' => (0x2C, false),
        _ => {
            if let Some(i) = SHIFTED_DIGITS.find(c) {
                return Some((0x1E + i as u64, true));
            }
            let &(plain, _, usage) = PUNCT.iter().find(|(p, s, _)| *p == c || *s == c)?;
            (usage, c != plain)
        }
    })
}

/// 0 = not tried yet, 1 = device needs the stream (iOS 27+), 2 = it refuses one (older iOS).
static GATE_MODE: AtomicU8 = AtomicU8::new(0);

type Gate = Option<Stream>;

type Stream = (DisplayServiceClient<Box<dyn idevice::ReadWrite>>, UdpSocketHandle, UdpSocketHandle);

/// Starts the audio+video screen-sharing session (HEVC over plain RTP to the
/// returned video socket). Mirrors tools/src/coredevice_stream.rs.
/// `ssrc` is ours in the offer; RTCP we send must carry it.
async fn start_stream(
    adapter: &mut idevice::tcp::handle::AdapterHandle,
    handshake: &mut idevice::rsd::RsdHandshake,
    ssrc: u32,
) -> Result<Stream, IdeviceError> {
    let mut client = DisplayServiceClient::connect_rsd(adapter, handshake).await?;
    let audio_udp = adapter.bind_udp(0).await?;
    let video_udp = adapter.bind_udp(0).await?;
    let (host, peer) = (adapter.host_ip().to_string(), adapter.peer_ip().to_string());
    let call_info = CallInfoBlob {
        call_id: 0,
        client_version: 1,
        device_type: "Mac17,7".into(),
        framework_version: "2205.3.1".into(),
        os_version: "25F71".into(),
        device_name: None,
        audio_device_uid: None,
    };
    let session = uuid::Uuid::new_v4();
    let call_id = || uuid::Uuid::new_v4().to_string().to_uppercase();
    let audio_offer = build_screen_audio_offer(&call_id(), &call_info)?;
    client
        .start_media_stream(build_start_audio_parameters(
            &host, audio_udp.local_port(), &peer, 50000, audio_offer, 140, session,
        ))
        .await?;
    let video_offer = build_screen_video_offer(&call_id(), &call_info, ssrc)?;
    client
        .start_media_stream(build_start_video_parameters(
            &host, video_udp.local_port(), &peer, 50001, video_offer, 140, 1, session,
        ))
        .await?;
    Ok((client, audio_udp, video_udp))
}

/// Opens a stream just to hold backboardd's HID auth gate open; the RTP is never read.
/// None when the live stream already holds it, or on iOS that doesn't need it.
async fn open_gate(
    adapter: &mut idevice::tcp::handle::AdapterHandle,
    handshake: &mut idevice::rsd::RsdHandshake,
) -> Gate {
    if LIVE_ON.load(Ordering::Relaxed) || GATE_MODE.load(Ordering::Relaxed) == 2 {
        return None;
    }
    match start_stream(adapter, handshake, uuid::Uuid::new_v4().as_u128() as u32).await {
        Ok(gate) => {
            GATE_MODE.store(1, Ordering::Relaxed);
            // backboardd needs a moment to re-match HID surfaces to the stream.
            tokio::time::sleep(Duration::from_millis(300)).await;
            Some(gate)
        }
        Err(e) => {
            // Pre-27 devices reject remote control (9021) and don't need it.
            if GATE_MODE.load(Ordering::Relaxed) == 0 {
                tracing::info!("no HID media stream, continuing without: {e:?}");
                GATE_MODE.store(2, Ordering::Relaxed);
            }
            None
        }
    }
}

async fn close_gate(gate: Gate) {
    if let Some((mut client, _audio, _video)) = gate {
        let _ = client.stop_media_stream().await;
    }
}

// Live screen: the stream stays open for a whole run; a task depacketizes the
// HEVC and queues one Annex-B access unit (frame) at a time for the app to decode.
static LIVE_ON: AtomicBool = AtomicBool::new(false);
static KEYFRAME: AtomicBool = AtomicBool::new(false);
static LIVE: Mutex<Option<(DisplayServiceClient<Box<dyn idevice::ReadWrite>>, UdpSocketHandle, tokio::task::JoinHandle<()>)>> =
    Mutex::new(None);
static LIVE_FRAMES: Mutex<Option<mpsc::Receiver<Vec<u8>>>> = Mutex::new(None);

/// Starts the live screen stream (stops a previous one). Frames come from `probe_stream_next`.
/// Also holds the HID gate open, so touches skip `open_gate` while it runs.
///
/// # Safety
/// Handles must be valid and come from this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_stream_start(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    probe_stream_stop();
    let res = run_sync_local(async move {
        let (a, h) = unsafe { (&mut (*adapter).0, &mut (*handshake).0) };
        let ssrc = uuid::Uuid::new_v4().as_u128() as u32;
        let (client, audio, video) = start_stream(a, h, ssrc).await?;
        KEYFRAME.store(false, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        let task = tokio::spawn(async move {
            let mut depack = HevcDepacketizer::new();
            let mut last_ts = None;
            let mut fir_seq = 0u8;
            // A frame ends on the RTP marker bit, or at the latest when the next timestamp starts.
            let flush = |d: &mut HevcDepacketizer| {
                let out = d.take_output();
                out.is_empty() || tx.send(out).is_ok()
            };
            while let Ok(dg) = video.recv().await {
                if is_rtcp(&dg.data) {
                    continue;
                }
                let Some(pkt) = RtpPacket::parse(&dg.data) else { continue };
                if KEYFRAME.swap(false, Ordering::Relaxed) {
                    fir_seq = fir_seq.wrapping_add(1);
                    let request = build_keyframe_request(ssrc, "iphoneuse", pkt.ssrc, &[], fir_seq);
                    let _ = video.send_to(dg.source_port, request).await; // RTCP is muxed on the RTP port
                }
                if last_ts.is_some_and(|t| t != pkt.timestamp) && !flush(&mut depack) {
                    break;
                }
                last_ts = Some(pkt.timestamp);
                depack.push(pkt.sequence_number, pkt.timestamp, pkt.payload);
                if pkt.marker && !flush(&mut depack) {
                    break;
                }
            }
        });
        *LIVE.lock().unwrap() = Some((client, audio, task));
        *LIVE_FRAMES.lock().unwrap() = Some(rx);
        LIVE_ON.store(true, Ordering::Relaxed);
        GATE_MODE.store(1, Ordering::Relaxed);
        Ok::<(), IdeviceError>(())
    });
    match res {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Waits up to `timeout_ms` for the next frame (Annex-B HEVC, free with `idevice_data_free`).
/// Returns 1 with a frame, 0 on timeout, -1 when no stream is running or it ended.
///
/// # Safety
/// `out_data` and `out_len` must be valid pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_stream_next(timeout_ms: u64, out_data: *mut *mut u8, out_len: *mut usize) -> i32 {
    if out_data.is_null() || out_len.is_null() {
        return -1;
    }
    let guard = LIVE_FRAMES.lock().unwrap();
    let Some(rx) = guard.as_ref() else { return -1 };
    match rx.recv_timeout(Duration::from_millis(timeout_ms)) {
        Ok(frame) => {
            let frame = frame.into_boxed_slice();
            unsafe {
                *out_len = frame.len();
                *out_data = Box::into_raw(frame) as *mut u8;
            }
            1
        }
        Err(mpsc::RecvTimeoutError::Timeout) => 0,
        Err(mpsc::RecvTimeoutError::Disconnected) => -1,
    }
}

/// Stops the live stream, if any. `probe_stream_next` then returns -1.
#[unsafe(no_mangle)]
pub extern "C" fn probe_stream_stop() {
    LIVE_ON.store(false, Ordering::Relaxed);
    let Some((mut client, _audio, task)) = LIVE.lock().unwrap().take() else { return };
    task.abort(); // drops the frame sender, so a waiting `probe_stream_next` returns -1
    run_sync_local(async move {
        let _ = client.stop_media_stream().await;
    });
}

/// Asks the device for a keyframe (RTCP PLI + FIR), sent with the next packet received.
/// The decoder needs one after it resets, since later frames only carry changes.
#[unsafe(no_mangle)]
pub extern "C" fn probe_stream_keyframe() {
    KEYFRAME.store(true, Ordering::Relaxed);
}
