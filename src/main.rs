use chrono::{DateTime, Local, TimeDelta};
use crossbeam_queue::ArrayQueue;
use notify::{RecursiveMode, Watcher};
use std::fs::File;
use std::io::{ErrorKind, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::path::Path;
use std::sync::Arc;
use std::thread::{self};

const MAX_FILE_RECORDING_DURATION: TimeDelta = TimeDelta::minutes(1);

#[derive(Clone)]
struct Message {
    video_data: Vec<u8>,
    from: SocketAddr,
    id: usize,
    at: DateTime<Local>,
}

fn receive_stream_udp_forever(
    port: u16,
    disk_ring_buffer: Arc<ArrayQueue<Message>>,
    net_ring_buffer: Arc<ArrayQueue<Message>>,
) -> std::io::Result<()> {
    let socket = std::net::UdpSocket::bind(format!("0.0.0.0:{}", port))?;
    let mut msg_id = 0usize;

    loop {
        let mut buf = [0; 4096];
        let (amt, src) = socket.recv_from(&mut buf)?;

        let buf = &buf[..amt];
        log::trace!(from:? =src, port, amt ; "received UDP packet");

        let msg = Message {
            video_data: buf.to_vec(),
            from: src,
            id: msg_id,
            at: chrono::offset::Local::now(),
        };
        disk_ring_buffer.force_push(msg.clone());
        net_ring_buffer.force_push(msg);

        log::trace!(msg_id; "received and forwarded camera packet");

        msg_id = msg_id.wrapping_add(1);
    }
}

fn open_output_file(
    now: &DateTime<Local>,
    recording_beginning: &mut DateTime<Local>,
) -> std::io::Result<File> {
    let path = format!("{}.ts", now.format("%FT%H:%M:%S"));

    let video_file = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(&path)?;

    log::info!(path; "opened new output file");
    *recording_beginning = *now;

    Ok(video_file)
}

fn write_to_disk_forever(disk_ring_buffer: Arc<ArrayQueue<Message>>) -> std::io::Result<()> {
    let mut recording_beginning = chrono::offset::Local::now();
    let mut video_file = open_output_file(&chrono::offset::Local::now(), &mut recording_beginning)?;

    loop {
        if let Some(msg) = disk_ring_buffer.pop() {
            let _ = video_file.write_all(&msg.video_data).map_err(|err| {
                log::error!(err:?, from:? = msg.from; "failed to write video to disk");
            });

            let duration_since_recording_beginning = msg.at - recording_beginning;

            if duration_since_recording_beginning >= MAX_FILE_RECORDING_DURATION {
                video_file = open_output_file(&msg.at, &mut recording_beginning)?;
            }

            log::trace!(id=msg.id, len=msg.video_data.len(); "wrote message to disk");
        } else {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }
}

fn run_broadcast_server_forever(port: u16) -> std::io::Result<()> {
    let listener = TcpListener::bind(format!("0.0.0.0:{}", port))?;
    loop {
        for stream in listener.incoming() {
            let mut stream = stream?;
            thread::spawn(move || {
                let _ = handle_broadcast_client(&mut stream);
            });
        }
    }
}

fn handle_broadcast_client(stream: &mut TcpStream) -> std::io::Result<()> {
    let (tx, rx) = std::sync::mpsc::channel();
    let mut watcher = notify::RecommendedWatcher::new(tx, notify::Config::default()).unwrap();

    watcher
        .watch(Path::new("."), RecursiveMode::NonRecursive)
        .unwrap();

    let mut offset = 0u64;
    let mut input_file = None;
    for res in rx {
        match res {
            Ok(event)
                if event.kind == notify::EventKind::Create(notify::event::CreateKind::File) =>
            {
                let video_file = event
                    .paths
                    .iter()
                    .find(|x| x.extension().unwrap_or_default() == "ts");

                if let Some(path) = video_file {
                    log::info!(path:?; "new video file");
                    input_file = Some(File::open(path).unwrap());
                    offset = 0;
                }
            }
            Ok(event)
                if event.kind
                    == notify::EventKind::Modify(notify::event::ModifyKind::Data(
                        notify::event::DataChange::Any,
                    )) =>
            {
                if input_file.is_none() {
                    input_file = Some(File::open(event.paths.first().unwrap()).unwrap());
                    offset = input_file.as_ref().unwrap().metadata().unwrap().len();
                }

                let old_offset = offset;
                let offet_ptr: *mut i64 = &mut (offset as i64);
                let sent = unsafe {
                    libc::sendfile(
                        stream.as_raw_fd(),
                        input_file.as_ref().unwrap().as_raw_fd(),
                        offet_ptr,
                        8192,
                    )
                };
                if sent == -1 {
                    log::error!(old_offset; "failed to sendfile(2)");
                    return Err(std::io::Error::from(ErrorKind::UnexpectedEof));
                }

                offset = offset.saturating_add(sent as u64);

                log::trace!( sent, old_offset, new_offset=offset; "served message");
            }
            Err(err) => log::error!(err:?; "watch error"),
            _ => {}
        }
    }

    Ok(())
}

fn main() {
    // Initialize the logger.
    std_logger::Config::logfmt().init();

    let disk_ring_buffer = Arc::new(ArrayQueue::new(256));
    let net_ring_buffer = Arc::new(ArrayQueue::new(256));

    let disk_ring_buffer1 = disk_ring_buffer.clone();
    let net_ring_buffer1 = net_ring_buffer.clone();
    thread::spawn(move || {
        receive_stream_udp_forever(12345, disk_ring_buffer1, net_ring_buffer1).unwrap();
    });

    let disk_ring_buffer2 = disk_ring_buffer.clone();
    thread::spawn(move || {
        write_to_disk_forever(disk_ring_buffer2).unwrap();
    });

    run_broadcast_server_forever(8082).unwrap();
}
