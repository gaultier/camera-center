use crossbeam_channel::{bounded, Receiver, Sender};
use std::io::Write;
use std::thread;

fn receive_stream_udp_forever(port: u16, sender: Sender<Vec<u8>>) -> std::io::Result<()> {
    let socket = std::net::UdpSocket::bind(format!("0.0.0.0:{}", port))?;

    loop {
        let mut buf = [0; 4096];
        let (amt, src) = socket.recv_from(&mut buf)?;

        let msg = &buf[..amt];
        log::debug!(from:? =src, port, buf:?=msg; "received UDP packet");

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

fn main() {
    // Initialize the logger.
    std_logger::Config::logfmt().init();

    let (s, r1) = bounded(256);
    // let r2 = r1.clone();
    thread::spawn(move || {
        receive_stream_udp_forever(12345, s).unwrap();
    });
    write_to_disk(r1).unwrap();
}
