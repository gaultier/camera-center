use crossbeam_channel::{bounded, Receiver, Sender};
use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::thread;

fn receive_stream_udp_forever(port: u16, sender: Sender<Vec<u8>>) -> std::io::Result<()> {
    let socket = std::net::UdpSocket::bind(format!("0.0.0.0:{}", port))?;

    loop {
        let mut buf = [0; 4096];
        let (amt, src) = socket.recv_from(&mut buf)?;

        let msg = &buf[..amt];
        log::debug!(from:? =src, port, amt ; "received UDP packet");

        let _ = sender.send(msg.to_vec()).map_err(|err| {
            log::error!(err:?; "failed to send message");
        });
    }
}

fn write_to_disk(receiver: Receiver<Vec<u8>>) -> std::io::Result<()> {
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

        let _ = file.write_all(&msg).map_err(|err| {
            log::error!(err:?; "failed to write to disk");
        });
    }
}

fn run_broadcast_server(port: u16, receiver: Receiver<Vec<u8>>) -> std::io::Result<()> {
    let listener = TcpListener::bind(format!("0.0.0.0:{}", port))?;

    loop {
        for stream in listener.incoming() {
            handle_client(&mut stream?, receiver.clone());
        }
    }
}

fn handle_client(stream: &mut TcpStream, receiver: Receiver<Vec<u8>>) {
    loop {
        let msg = match receiver.recv() {
            Ok(msg) => msg,
            Err(err) => {
                log::error!(err:?; "failed to receive message");
                continue;
            }
        };

        if let Err(err) = stream.write_all(&msg) {
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
        receive_stream_udp_forever(12345, s).unwrap();
    });
    thread::spawn(move || {
        write_to_disk(r1).unwrap();
    });

    run_broadcast_server(8082, r2).unwrap();
}
