use crossbeam_channel::{bounded, Receiver, Sender};
use std::io::Write;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::thread::{self};

fn compute_hash(data: &[u8]) -> u64 {
    let mut h = 0x100u64;
    for x in data {
        h ^= *x as u64;
        h = h.wrapping_mul(1111111111111111111u64);
    }

    h
}

#[derive(Clone)]
struct Message {
    video_data: Vec<u8>,
    from: SocketAddr,
    hash: u64,
}

fn receive_stream_udp_forever(
    port: u16,
    sender_disk: Sender<Message>,
    sender_broadcast: Sender<Message>,
) -> std::io::Result<()> {
    let socket = std::net::UdpSocket::bind(format!("0.0.0.0:{}", port))?;

    loop {
        let mut buf = [0; 4096];
        let (amt, src) = socket.recv_from(&mut buf)?;

        let buf = &buf[..amt];
        log::debug!(from:? =src, port, amt ; "received UDP packet");

        let hash = compute_hash(buf);
        let msg = Message {
            video_data: buf.to_vec(),
            hash,
            from: src,
        };
        let _ = sender_disk.send(msg.clone()).map_err(|err| {
            log::error!(err:?; "failed to send message");
        });
        let _ = sender_broadcast.send(msg).map_err(|err| {
            log::error!(err:?; "failed to send message");
        });

        log::debug!(hash; "received and forwarded camera packet");
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
        log::debug!(hash=msg.hash, len=msg.video_data.len(); "wrote message to disk");
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
        log::debug!(hash=msg.hash, len=msg.video_data.len(); "served message");
    }
}

fn main() {
    // Initialize the logger.
    std_logger::Config::logfmt().init();

    let (sender_disk, receiver_disk) = bounded(256);
    let (sender_broadcast, receiver_broadcast) = bounded(256);

    thread::spawn(move || {
        receive_stream_udp_forever(12345, sender_disk, sender_broadcast).unwrap();
    });
    thread::spawn(move || {
        write_to_disk(receiver_disk).unwrap();
    });

    run_broadcast_server(8082, receiver_broadcast).unwrap();
}
