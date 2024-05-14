use crossbeam_channel::{bounded, Receiver, Sender};
use std::io::Read;
use std::io::Write;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::thread::{self};

struct Message {
    video_data: Vec<u8>,
    from: SocketAddr,
}

fn receive_stream_from_camera(from: &SocketAddr, sender: Sender<Message>) -> std::io::Result<()> {
    let mut socket = std::net::TcpStream::connect(from)?;

    loop {
        let mut buf = [0; 4096];
        let read_count = socket.read(&mut buf)?;

        let buf = &buf[..read_count];
        log::debug!(from:?, read_count ; "received packet");

        let msg = Message {
            video_data: buf.to_vec(),
            from: *from,
        };
        let _ = sender.send(msg).map_err(|err| {
            log::error!(err:?; "failed to send message");
        });
    }
}

fn write_to_disk(receiver: Receiver<Message>) -> std::io::Result<()> {
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open("cam.mpegts")?;

    loop {
        let msg = match receiver.recv() {
            Ok(msg) => msg,
            Err(err) => {
                log::error!(err:?; "failed to receive message");
                continue;
            }
        };
        let _ = file.write_all(&msg.video_data).map_err(|err| {
            log::error!(err:?; "failed to write to disk");
        });
        log::debug!(len=msg.video_data.len(); "wrote message to disk");
    }
}

fn run_broadcast_server(port: u16, receiver: Receiver<Message>) -> std::io::Result<()> {
    let listener = TcpListener::bind(format!("0.0.0.0:{}", port))?;

    loop {
        for stream in listener.incoming() {
            let r = receiver.clone();
            handle_client(&mut stream?, r);
        }
    }
}

fn handle_client(stream: &mut TcpStream, receiver: Receiver<Message>) {
    loop {
        let msg = match receiver.recv() {
            Ok(msg) => msg,
            Err(err) => {
                log::error!(err:?; "failed to receive message");
                continue;
            }
        };

        if let Err(err) = stream.write_all(&msg.video_data) {
            log::error!(err:?; "failed to write to tcp stream");
            return;
        }
    }
}

fn main() {
    // Initialize the logger.
    std_logger::Config::logfmt().init();

    let (s, r1) = bounded(256);
    let r2 = r1.clone();

    thread::spawn(move || {
        receive_stream_from_camera(&SocketAddr::from(([192, 168, 1, 125], 12345)), s).unwrap();
    });
    thread::spawn(move || {
        write_to_disk(r1).unwrap();
    });

    run_broadcast_server(8082, r2).unwrap();
}
