use super::*;

fn read_all(method: &str, answer: &[u8], piece: usize) -> Result<Vec<Piece>, Malformed> {
    let mut reader = ResponseReader::new(method);
    let mut pieces = Vec::new();
    for part in answer.chunks(piece) {
        pieces.extend(reader.feed(part)?);
    }
    pieces.extend(reader.finish()?);
    Ok(pieces)
}

fn body(pieces: &[Piece]) -> Vec<u8> {
    pieces.iter().filter_map(|piece| if let Piece::Data(data) = piece { Some(data.clone()) } else { None }).flatten().collect()
}

#[test]
fn a_sized_body_ends_at_its_length_in_any_split() {
    let answer = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello";
    for piece in [1, 3, answer.len()] {
        let pieces = read_all("GET", answer, piece).expect("reads");
        assert!(matches!(&pieces[0], Piece::Head { status: 200, headers } if headers.len() == 2));
        assert_eq!(body(&pieces), b"hello");
        assert_eq!(pieces.last(), Some(&Piece::End));
    }
}

#[test]
fn a_chunked_body_is_joined_and_its_trailer_skipped() {
    let answer = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;x=y\r\npedia\r\n0\r\nX-T: 1\r\n\r\n";
    for piece in [1, 7, answer.len()] {
        let pieces = read_all("GET", answer, piece).expect("reads");
        assert_eq!(body(&pieces), b"Wikipedia");
        assert_eq!(pieces.iter().filter(|piece| **piece == Piece::End).count(), 1);
    }
}

#[test]
fn a_body_without_framing_runs_to_the_close() {
    let pieces = read_all("GET", b"HTTP/1.0 200 OK\r\n\r\nall of it", 4).expect("reads");
    assert_eq!(body(&pieces), b"all of it");
}

#[test]
fn a_head_request_and_a_not_modified_have_no_body() {
    let pieces = read_all("HEAD", b"HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n", 100).expect("reads");
    assert_eq!(pieces.len(), 2);
    let pieces = read_all("GET", b"HTTP/1.1 304 Not Modified\r\n\r\n", 100).expect("reads");
    assert_eq!(pieces.len(), 2);
}

#[test]
fn an_interim_continue_is_skipped() {
    let pieces = read_all("POST", b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n", 100)
        .expect("reads");
    assert!(matches!(pieces[0], Piece::Head { status: 201, .. }));
}

#[test]
fn a_close_before_the_length_is_incomplete_and_garbage_is_not_http() {
    assert_eq!(read_all("GET", b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort", 100), Err(Malformed::Incomplete));
    assert_eq!(read_all("GET", b"SSH-2.0-OpenSSH\r\n\r\n", 100), Err(Malformed::NotHttp));
}

#[test]
fn the_request_names_loopback_asks_for_identity_and_sizes_its_body() {
    let request = PreviewProxyRequest {
        id: 1,
        port: 3000,
        method: "POST".to_owned(),
        target: "/api?x=1".to_owned(),
        headers: vec![
            PreviewHeader { name: "Content-Type".to_owned(), value: "application/json".to_owned() },
            PreviewHeader { name: "Host".to_owned(), value: "evil".to_owned() },
        ],
        body: Some(b"{}".to_vec()),
    };
    let text = String::from_utf8(request_bytes(&request)).expect("text");
    assert_eq!(
        text,
        "POST /api?x=1 HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nContent-Type: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}"
    );
}
