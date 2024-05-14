use crossbeam_queue::ArrayQueue;
use std::io::Write;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::Arc;
use std::thread::{self};
use std::time::Duration;

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
    disk_ring_buffer: Arc<ArrayQueue<Message>>,
    net_ring_buffer: Arc<ArrayQueue<Message>>,
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
            from: src,
            hash,
        };
        disk_ring_buffer.force_push(msg.clone());
        net_ring_buffer.force_push(msg);

        log::debug!(hash; "received and forwarded camera packet");
    }
}

fn write_to_disk(disk_ring_buffer: Arc<ArrayQueue<Message>>) -> std::io::Result<()> {
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open("cam.mpegts")?;

    loop {
        if let Some(msg) = disk_ring_buffer.pop() {
            let _ = file.write_all(&msg.video_data).map_err(|err| {
                log::error!(err:?; "failed to write to disk");
            });
            log::debug!(hash=msg.hash, len=msg.video_data.len(); "wrote message to disk");
        } else {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

fn run_broadcast_server(
    port: u16,
    net_ring_buffer: Arc<ArrayQueue<Message>>,
) -> std::io::Result<()> {
    let listener = TcpListener::bind(format!("0.0.0.0:{}", port))?;

    loop {
        for stream in listener.incoming() {
            let net_ring_buffer1 = net_ring_buffer.clone();
            let mut stream = stream?;
            thread::spawn(move || {
                handle_client(&mut stream, net_ring_buffer1);
            });
        }
    }
}

fn handle_client(stream: &mut TcpStream, net_ring_buffer: Arc<ArrayQueue<Message>>) {
    loop {
        if let Some(msg) = net_ring_buffer.pop() {
            if let Err(err) = stream.write_all(&msg.video_data) {
                log::error!(err:?; "failed to write to tcp stream");
                return;
            }
            log::debug!(hash=msg.hash, len=msg.video_data.len(); "served message");
        } else {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
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
        write_to_disk(disk_ring_buffer2).unwrap();
    });

    run_broadcast_server(8082, net_ring_buffer).unwrap();
}
