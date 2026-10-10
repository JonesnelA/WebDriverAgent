//! On-device CoreDevice experiment. No XCTest or direct IOKit injection.
use idevice::{IdeviceService, RsdService, ReadWrite, pairing_file::PairingFile,
    provider::TcpProvider, core_device_proxy::CoreDeviceProxy, rsd::RsdHandshake,
    heartbeat::HeartbeatClient, core_device::{UniversalHidServiceClient, DisplayServiceClient,
    CallInfoBlob, build_screen_audio_offer, build_screen_video_offer,
    build_start_audio_parameters, build_start_video_parameters}};
use std::{ffi::{CStr, CString, c_char}, sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}}, time::Duration};
use tokio::{runtime::Runtime, sync::Mutex as AsyncMutex, task::JoinHandle};
mod diagnostics;
use diagnostics::service_error;

static LAST_ERROR: Mutex<String> = Mutex::new(String::new());
fn error(stage: &str, cause: impl std::fmt::Display) { *LAST_ERROR.lock().unwrap() = format!("{stage}: {cause}"); }
type Hid = UniversalHidServiceClient<Box<dyn ReadWrite>>;
type Display = DisplayServiceClient<Box<dyn ReadWrite>>;
struct State { hid: Hid, display: Option<Display>, contact: Option<(u16,u16)>, broken: bool }
pub struct Engine { runtime: Runtime, state: AsyncMutex<State>, provider: Arc<TcpProvider>,
    alive: Arc<AtomicBool>, workers: Vec<JoinHandle<()>> }

fn point(x: f64, y: f64, orientation: u32) -> Result<(u16,u16), &'static str> {
    if !x.is_finite() || !y.is_finite() || !(0.0..1.0).contains(&x) || !(0.0..1.0).contains(&y) {
        return Err("coordinate outside image");
    }
    let (x,y) = match orientation { 0 => (x,y), 1 => (1.0-y,x), 2 => (y,1.0-x),
        3 => (1.0-x,1.0-y), _ => return Err("unknown orientation") };
    Ok(((x*65535.0).round() as u16,(y*65535.0).round() as u16))
}

async fn release(state: &mut State) -> bool {
    if let Some((x,y)) = state.contact.take() {
        if !matches!(tokio::time::timeout(Duration::from_secs(2), state.hid.send_touchscreen(0x02,x,y,None)).await, Ok(Ok(()))) {
            state.broken = true;
            return false;
        }
    }
    true
}

async fn open(provider: Arc<TcpProvider>, media: bool) -> Result<(State,Arc<AtomicBool>,Vec<JoinHandle<()>>),String> {
    // Pairing material stays in the app; never print the provider or its errors' Debug representation.
    let mut heartbeat = HeartbeatClient::connect(&*provider).await.map_err(|_| "heartbeat: check LocalDevVPN, pairing and Developer Mode")?;
    let alive = Arc::new(AtomicBool::new(true));
    let hb_alive = alive.clone();
    let hb = tokio::spawn(async move {
        let mut interval = 30;
        loop {
            match heartbeat.get_marco(interval).await {
                Ok(next) => { interval = next.clamp(1,60); if heartbeat.send_polo().await.is_err() { break; } },
                Err(_) => break,
            }
        }
        hb_alive.store(false, Ordering::Release);
        error("heartbeat", "connection ended; reconnect before sending more input");
    });
    let setup = async {
        let proxy = CoreDeviceProxy::connect(&*provider).await.map_err(|_| "CoreDevice: developer services unavailable; check DDI")?;
        let port = proxy.tunnel_info().server_rsd_port;
        let mut adapter = proxy.create_software_tunnel().map_err(|_| "CoreDevice: software tunnel failed")?.to_async_handle();
        let mut rsd = RsdHandshake::new(adapter.connect(port).await.map_err(|_| "RSD: tunnel connection failed")?).await.map_err(|_| "RSD: handshake failed")?;
        let mut workers = Vec::new();
        let mut display = None;
        if media {
            let mut client = Display::connect_rsd(&mut adapter, &mut rsd).await.map_err(|e| service_error("screen session: displayservice connection failed", &e))?;
            let audio = adapter.bind_udp(0).await.map_err(|_| "screen session: audio receiver failed")?;
            let video = adapter.bind_udp(0).await.map_err(|_| "screen session: video receiver failed")?;
            let receiver = adapter.host_ip().to_string(); let sender = adapter.peer_ip().to_string();
            // Negotiation constants from the pinned idevice MIT-licensed reference tool.
            let info = CallInfoBlob { call_id:0, client_version:1, device_type:"Mac17,7".into(),
                framework_version:"2205.3.1".into(), os_version:"25F71".into(), device_name:None, audio_device_uid:None };
            let session = uuid::Uuid::new_v4();
            let audio_offer = build_screen_audio_offer(&uuid::Uuid::new_v4().to_string().to_uppercase(), &info).map_err(|e| service_error("screen session: audio offer failed", &e))?;
            client.start_media_stream(build_start_audio_parameters(&receiver,audio.local_port(),&sender,50000,audio_offer,140,session))
                .await.map_err(|e| service_error("screen session: audio negotiation failed", &e))?;
            let ssrc = uuid::Uuid::new_v4().as_u128() as u32;
            let video_offer = build_screen_video_offer(&uuid::Uuid::new_v4().to_string().to_uppercase(),&info,ssrc).map_err(|e| service_error("screen session: video offer failed", &e))?;
            if let Err(e) = client.start_media_stream(build_start_video_parameters(&receiver,video.local_port(),&sender,50001,video_offer,140,1,session)).await {
                let _ = client.stop_media_stream().await;
                return Err(service_error("screen session: video negotiation failed", &e));
            }
            // Drain RTP for the whole session instead of accumulating unread video in RAM.
            workers.push(tokio::spawn(async move { while audio.recv().await.is_ok() {} }));
            workers.push(tokio::spawn(async move { while video.recv().await.is_ok() {} }));
            display = Some(client);
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        let hid_result = async {
            let mut hid = Hid::connect_rsd(&mut adapter,&mut rsd).await.map_err(|e| service_error("HID: connection failed", &e))?;
            let surfaces = hid.list_connected_services().await.map_err(|e| service_error("HID: inventory failed", &e))?;
            if !surfaces.iter().any(|s| s.service_id == 257) { return Err("HID: mainTouchscreen missing".into()); }
            Ok(hid)
        }.await;
        match hid_result {
            Ok(hid) => Ok((State {hid,display,contact:None,broken:false}, workers)),
            Err(e) => { if let Some(mut display) = display { let _ = display.stop_media_stream().await; }
                for worker in workers { worker.abort(); } Err(e) },
        }
    };
    match tokio::time::timeout(Duration::from_secs(35),setup).await {
        Ok(Ok((state,mut workers))) => { workers.push(hb); Ok((state,alive,workers)) },
        Ok(Err(e)) => { hb.abort(); Err(e.into()) },
        Err(_) => { hb.abort(); Err("device setup timed out; stop other mirroring tools and reconnect".into()) },
    }
}

#[no_mangle]
pub unsafe extern "C" fn tb_open(path: *const c_char, media: i32) -> *mut Engine {
    if path.is_null() { return std::ptr::null_mut(); }
    let path = match CStr::from_ptr(path).to_str() { Ok(p)=>p,Err(_)=>return std::ptr::null_mut() };
    let pair = match PairingFile::read_from_file(path) { Ok(p)=>p,Err(_)=> { error("pairing","invalid pairing file"); return std::ptr::null_mut(); } };
    let provider = Arc::new(TcpProvider { addr:"10.7.0.1".parse().unwrap(), scope_id:None, pairing_file:pair, label:"TouchBridge-iPad".into() });
    let runtime = match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() {
        Ok(r)=>r,Err(_)=> {error("runtime","could not start");return std::ptr::null_mut();} };
    match runtime.block_on(open(provider.clone(),media != 0)) {
        Ok((state,alive,workers)) => Box::into_raw(Box::new(Engine {runtime,state:AsyncMutex::new(state),provider,alive,workers})),
        Err(e) => { error("setup",e); std::ptr::null_mut() },
    }
}

#[no_mangle]
pub unsafe extern "C" fn tb_touch(engine: *mut Engine, phase: u32, x:f64,y:f64,orientation:u32) -> i32 {
    if engine.is_null() {return -1;}
    let e = &*engine;
    let result = e.runtime.block_on(async {
        let mut s = e.state.lock().await;
        if phase == 3 { return if release(&mut s).await {Ok(())} else {Err("release not acknowledged; reconnect HID")}; }
        if !e.alive.load(Ordering::Acquire) || s.broken { release(&mut s).await; return Err("HID connection ended"); }
        let p = point(x,y,orientation)?;
        match phase {
            0 if s.contact.is_none() => s.contact = Some(p),
            1 if s.contact.is_some() => s.contact = Some(p),
            2 if s.contact.is_some() => {},
            _ => return Err("invalid contact lifecycle"),
        }
        let r = tokio::time::timeout(Duration::from_secs(3),s.hid.send_touchscreen(if phase == 2 {0x02} else {0xC2},p.0,p.1,None)).await;
        if !matches!(r,Ok(Ok(()))) { release(&mut s).await; s.broken=true; return Err("HID send uncertain; contact released, no replay"); }
        if phase == 2 {s.contact=None;}
        Ok(())
    });
    match result {Ok(())=>0,Err(e)=> {error("touch",e);-1}}
}

#[no_mangle]
pub unsafe extern "C" fn tb_screenshot(engine:*mut Engine,length:*mut usize)->*mut u8 {
    if engine.is_null() || length.is_null() {return std::ptr::null_mut();}
    *length=0;
    let e=&*engine;
    let capture=async {
        let proxy=CoreDeviceProxy::connect(&*e.provider).await?;
        let port=proxy.tunnel_info().server_rsd_port;
        let mut adapter=proxy.create_software_tunnel()?.to_async_handle();
        let mut rsd=RsdHandshake::new(adapter.connect(port).await?).await?;
        let mut remote=idevice::dvt::remote_server::RemoteServerClient::connect_rsd(&mut adapter,&mut rsd).await?;
        remote.read_message(0).await?;
        let mut screenshot=idevice::dvt::screenshot::ScreenshotClient::new(&mut remote).await?;
        screenshot.take_screenshot().await
    };
    match e.runtime.block_on(async {tokio::time::timeout(Duration::from_secs(8),capture).await}) {
        Ok(Ok(data)) if data.len()<=24*1024*1024 => {let data=data.into_boxed_slice();*length=data.len();Box::into_raw(data) as *mut u8},
        _=> {error("screenshot","capture failed or timed out");std::ptr::null_mut()},
    }
}

#[no_mangle]
pub unsafe extern "C" fn tb_data_free(data:*mut u8,length:usize) { if !data.is_null() {drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(data,length)));} }
#[no_mangle]
pub extern "C" fn tb_last_error()->*mut c_char {CString::new(LAST_ERROR.lock().unwrap().replace('\0'," ")).unwrap().into_raw()}
#[no_mangle]
pub unsafe extern "C" fn tb_string_free(s:*mut c_char) {if !s.is_null() {drop(CString::from_raw(s));}}
#[no_mangle]
pub unsafe extern "C" fn tb_close(engine:*mut Engine) {
    if engine.is_null() {return;}
    let e=Box::from_raw(engine);
    e.runtime.block_on(async {let mut s=e.state.lock().await;release(&mut s).await;
        if let Some(mut d)=s.display.take() {let _=tokio::time::timeout(Duration::from_secs(2),d.stop_media_stream()).await;}});
    for worker in &e.workers {worker.abort();}
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn mapping_and_validation() {assert_eq!(point(0.35,0.60,1).unwrap(),(26214,22937));
        assert!(point(f64::NAN,0.2,0).is_err());assert!(point(1.0,0.2,0).is_err());assert!(point(0.2,0.3,9).is_err());}
}
