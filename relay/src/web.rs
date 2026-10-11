//! The site, served from the same process as the relay.
//!
//! # Why this is handwritten
//!
//! A static file server for a page of HTML, a stylesheet, a script and four images is a small
//! enough subset of HTTP that writing it is cheaper than depending on it. The alternative —
//! `axum` and `tower-http`, or `hyper` and a handler — brings a framework, a service abstraction
//! and a dozen transitive crates to a process whose entire design principle is that it should be
//! too stupid to break the end-to-end property it exists to provide. Nothing below reads a request
//! body, consults a database, or knows what a session is.
//!
//! # What it does not do
//!
//! No POST, no compression, no directory listings, no `If-Modified-Since`, no multi-range
//! requests, and no symlinks out of the root. Those are all things a real file server would do.
//! Some of them would be work with no caller; two are refusals, and they are deliberate: a
//! directory listing hands a stranger the shape of the filesystem, and a path that resolves
//! outside the root is how a static server becomes a file disclosure.
//!
//! Single ranges *are* supported, which is the one of these that earned its keep: the site serves
//! the Mac app's disk image, and a download that cannot resume is a download that never finishes
//! on a train.
//!
//! # Safety rules, in one place
//!
//! Every request path is percent-decoded and then split on `/`, and any component that is empty,
//! `.`, `..`, or begins with a dot is refused rather than normalised. Decoding happens *before*
//! splitting, so `%2e%2e%2f` is a refusal and not an escape, and starting a name with a dot is
//! refused so that a file dropped next to the site — `.env`, a `.git` directory — is not served
//! because of where it happens to sit.

use std::io::SeekFrom;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};

use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tracing::{debug, info, warn};

/// The largest request head that will be read: request line and headers together.
///
/// A browser sends a few hundred bytes for a page like this one. The limit exists so that a client
/// which never sends a blank line cannot make the server allocate without bound.
const MAX_HEAD: usize = 8 * 1024;

/// How many requests one connection may carry before it is closed.
const MAX_REQUESTS: u32 = 64;

/// How long the first request of a connection may take, and how long a keep-alive connection may
/// sit idle between requests.
const HEAD_TIMEOUT: Duration = Duration::from_secs(10);
const IDLE_TIMEOUT: Duration = Duration::from_secs(15);

/// Serves the site until the process ends.
///
/// A failure to accept is logged and slept off rather than fatal, for the same reason the relay's
/// own accept loops behave that way: a transient error — a file descriptor limit reached, a
/// connection reset between the kernel accepting it and this process hearing about it — is not a
/// reason to stop serving.
pub async fn serve(listener: TcpListener, root: Arc<PathBuf>) {
    loop {
        match listener.accept().await {
            Ok((stream, _peer)) => {
                let root = Arc::clone(&root);
                tokio::spawn(async move {
                    if let Err(error) = connection(stream, &root).await {
                        debug!(%error, "web connection ended");
                    }
                });
            }
            Err(error) => {
                warn!(%error, "could not accept a web connection");
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}

/// One connection: as many requests as it wants to make, until it stops or goes quiet.
async fn connection(mut stream: TcpStream, root: &Path) -> std::io::Result<()> {
    // The same reasoning as the control relay's: without this every response waits on Nagle, and
    // a page made of seven small files pays for it seven times.
    let _ = stream.set_nodelay(true);

    let mut buffer = Vec::with_capacity(1024);
    let mut first = true;

    for _ in 0..MAX_REQUESTS {
        let timeout = if first { HEAD_TIMEOUT } else { IDLE_TIMEOUT };
        first = false;

        let read = tokio::time::timeout(timeout, read_head(&mut stream, &mut buffer)).await;
        let head_len = match read {
            // The client closed between requests, which is the normal end of a keep-alive
            // connection and not worth a log line.
            Ok(Ok(None)) => return Ok(()),
            Ok(Ok(Some(len))) => len,
            Ok(Err(error)) => {
                let response = Response::text(431, "Request header fields are too large.");
                let _ = write_response(&mut stream, response, false, true).await;
                return Err(error);
            }
            // Nothing arrived in time. Closed quietly for the same reason as above.
            Err(_) => return Ok(()),
        };

        let head = String::from_utf8_lossy(&buffer[..head_len]).into_owned();
        buffer.drain(..head_len);

        let parsed = request_line(&head);
        let head_only = matches!(parsed.map(|(method, _, _)| method), Some("HEAD"));
        let close = matches!(connection_of(&head), Connection::Close);

        let response = respond(&head, root).await;
        // Read before the response is handed over, because writing it consumes the body — which is
        // a file handle for anything large enough to care about.
        let status = response.status;
        write_response(&mut stream, response, head_only, close).await?;

        // Errors end the connection, and so does a client that asked for that. Everything else
        // stays open for the next file — which, for this site, is seven of them.
        if close || (status != 200 && status != 206 && status != 304) {
            return Ok(());
        }
    }

    Ok(())
}

/// Reads until the end of the request head, returning how many bytes of `buffer` it occupies.
///
/// `None` means the client closed the connection cleanly before sending anything, which is how a
/// keep-alive connection is supposed to end.
async fn read_head(stream: &mut TcpStream, buffer: &mut Vec<u8>) -> std::io::Result<Option<usize>> {
    loop {
        if let Some(end) = find_head_end(buffer) {
            return Ok(Some(end));
        }

        if buffer.len() > MAX_HEAD {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "request head too large",
            ));
        }

        let mut chunk = [0u8; 1024];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            if buffer.is_empty() {
                return Ok(None);
            }
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "connection closed mid-request",
            ));
        }

        buffer.extend_from_slice(&chunk[..read]);
    }
}

/// Where the head ends: the offset just past the blank line that terminates it.
fn find_head_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|window| window == b"\r\n\r\n").map(|at| at + 4)
}

// ---------------------------------------------------------------------------
// The request
// ---------------------------------------------------------------------------

#[derive(Debug, PartialEq, Eq)]
enum Connection {
    KeepAlive,
    Close,
}

struct RequestHeaders {
    if_none_match: Option<String>,
    range: Option<String>,
}

fn request_line(head: &str) -> Option<(&str, &str, &str)> {
    let line = head.lines().next()?;
    let mut parts = line.split(' ');
    let method = parts.next()?;
    let target = parts.next()?;
    let version = parts.next()?;

    // Anything else on the request line — a fourth field, a second space in the target — is a
    // malformed request, and refusing it is cheaper than carrying a parser for it.
    if parts.next().is_some() || method.is_empty() || target.is_empty() {
        return None;
    }

    Some((method, target, version))
}

/// Whether the connection stays open, which depends on the version before it depends on anything
/// the client said: HTTP/1.1 keeps it open unless told to close, HTTP/1.0 closes unless told to
/// keep it open.
fn connection_of(head: &str) -> Connection {
    let version = request_line(head).map(|(_, _, version)| version).unwrap_or("HTTP/1.1");
    let mut connection = if version == "HTTP/1.0" {
        Connection::Close
    } else {
        Connection::KeepAlive
    };

    for line in head.lines().skip(1) {
        let Some((name, value)) = line.split_once(':') else { continue };
        if !name.eq_ignore_ascii_case("connection") {
            continue;
        }
        let value = value.trim();
        if value.eq_ignore_ascii_case("close") {
            connection = Connection::Close;
        } else if value.eq_ignore_ascii_case("keep-alive") {
            connection = Connection::KeepAlive;
        }
    }

    connection
}

fn request_headers(head: &str) -> RequestHeaders {
    let mut if_none_match = None;
    let mut range = None;

    for line in head.lines().skip(1) {
        let Some((name, value)) = line.split_once(':') else { continue };
        if name.eq_ignore_ascii_case("if-none-match") {
            if_none_match = Some(value.trim().to_string());
        } else if name.eq_ignore_ascii_case("range") {
            range = Some(value.trim().to_string());
        }
    }

    RequestHeaders { if_none_match, range }
}

// ---------------------------------------------------------------------------
// The response
// ---------------------------------------------------------------------------

struct Response {
    status: u16,
    reason: &'static str,
    content_type: &'static str,
    cache_control: &'static str,
    /// Extra headers, already formatted, without the trailing CRLF.
    extra: Vec<String>,
    body: Body,
}

/// What goes in the body.
///
/// A file is carried as an open handle and a window into it rather than as bytes, because the site
/// now serves a disk image. Reading twenty megabytes into a buffer per request is a way to let
/// three simultaneous downloads decide how much memory this process uses — and this process is
/// also relaying somebody's screen. The handle is opened before the headers are written, so a file
/// that has gone missing is a 404 rather than a 200 with a truncated body.
enum Body {
    Bytes(Vec<u8>),
    /// Already positioned: the seek happens in `respond`, before the status line is committed.
    File {
        file: tokio::fs::File,
        len: u64,
    },
}

impl Body {
    fn len(&self) -> u64 {
        match self {
            Body::Bytes(bytes) => bytes.len() as u64,
            Body::File { len, .. } => *len,
        }
    }

}

impl Response {
    fn text(status: u16, message: &str) -> Self {
        Self {
            status,
            reason: reason_for(status),
            content_type: "text/plain; charset=utf-8",
            cache_control: "no-cache",
            extra: Vec::new(),
            body: Body::Bytes(format!("{message}\n").into_bytes()),
        }
    }
}

fn reason_for(status: u16) -> &'static str {
    match status {
        200 => "OK",
        206 => "Partial Content",
        304 => "Not Modified",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        416 => "Range Not Satisfiable",
        431 => "Request Header Fields Too Large",
        505 => "HTTP Version Not Supported",
        _ => "Internal Server Error",
    }
}

async fn respond(head: &str, root: &Path) -> Response {
    let Some((method, target, version)) = request_line(head) else {
        return Response::text(400, "Malformed request.");
    };

    if !version.starts_with("HTTP/1.") {
        return Response::text(505, "Only HTTP/1.0 and HTTP/1.1 are served.");
    }

    if method != "GET" && method != "HEAD" {
        let mut response = Response::text(405, "This server serves GET and HEAD.");
        response.extra.push("Allow: GET, HEAD".into());
        return response;
    }

    // A target may carry a query string, and this site has no use for one — but a link with a
    // tracking parameter on it should still reach the page rather than a 404.
    let path = target.split(['?', '#']).next().unwrap_or(target);

    // An uptime check, and the only path here that is not a file.
    //
    // It is worth having because the site is served by *this* process: when `peeringd` stops,
    // every path — including this one — answers 502 at the edge. So a monitor pointed at
    // `/healthz` through the normal hostname answers "is the relay running", which is otherwise
    // discovered by a user who cannot connect. That is exactly how the outage on 18 September was
    // found, and it was found by hand.
    //
    // What it deliberately does not report: sessions, connected devices, registered Macs, or
    // load. An unauthenticated endpoint that describes how busy the service is hands anyone a
    // free intelligence feed, and the operator can read all of it from the logs. The version is
    // in the answer and that is a small disclosure too — it is bought back by being able to say
    // which build is deployed without opening a shell on the box.
    if path == "/healthz" {
        return Response::text(
            200,
            concat!("ok peeringd ", env!("CARGO_PKG_VERSION"), "\n"),
        );
    }

    let Some(file) = resolve(root, path) else {
        return Response::text(404, "Not found.");
    };

    let metadata = match tokio::fs::metadata(&file).await {
        Ok(metadata) if metadata.is_file() => metadata,
        // Directories are included here on purpose: there are no listings to serve, so a path that
        // happens to name one is the same answer as a path that names nothing.
        _ => return Response::text(404, "Not found."),
    };

    let modified = metadata.modified().unwrap_or(UNIX_EPOCH);
    let etag = format!(
        "\"{:x}-{:x}\"",
        modified.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0),
        metadata.len()
    );

    let headers = request_headers(head);
    if headers.if_none_match.as_deref() == Some(etag.as_str()) {
        return Response {
            status: 304,
            reason: reason_for(304),
            content_type: content_type(&file),
            cache_control: cache_control_for(&file),
            extra: vec![format!("ETag: {etag}")],
            body: Body::Bytes(Vec::new()),
        };
    }

    // Opened here rather than at the moment of writing, so that a file which cannot be opened is
    // still a status code this server can choose rather than a header already sent.
    let mut handle = match tokio::fs::File::open(&file).await {
        Ok(handle) => handle,
        Err(error) => {
            debug!(%error, path = %file.display(), "could not open a site file");
            return Response::text(404, "Not found.");
        }
    };

    let total = metadata.len();
    let mut extra = vec![
        format!("ETag: {etag}"),
        format!("Last-Modified: {}", http_date(modified)),
        // Advertised because it is now supported, and because a download manager that cannot
        // resume a 20 MB disk image over a train connection is a download that never finishes.
        "Accept-Ranges: bytes".to_string(),
    ];

    // A range request, which is what a browser or an updater sends when it is resuming something
    // it has already started.
    let mut status = 200;
    let (start, len) = match headers.range.as_deref().and_then(|value| parse_range(value, total)) {
        Some(Some((start, end))) => {
            status = 206;
            extra.push(format!("Content-Range: bytes {start}-{end}/{total}"));
            (start, end - start + 1)
        }
        // Asked for a window that does not exist. 416 rather than the whole file: a client that
        // asked for the tail of something that has since been replaced is better told so.
        Some(None) => {
            let mut response = Response::text(416, "That range is not within the file.");
            response.extra.push(format!("Content-Range: bytes */{total}"));
            return response;
        }
        None => (0, total),
    };

    // Positioned here rather than during the copy, for the same reason the file is opened here:
    // a seek that fails after a 206 has been sent is a truncated body with no way to say so.
    if start > 0 {
        if let Err(error) = handle.seek(SeekFrom::Start(start)).await {
            debug!(%error, path = %file.display(), "could not seek in a site file");
            return Response::text(500, "Could not read that file.");
        }
    }

    Response {
        status,
        reason: reason_for(status),
        content_type: content_type(&file),
        cache_control: cache_control_for(&file),
        extra,
        body: Body::File { file: handle, len },
    }
}

/// A single range from a `Range` header, as `(start, end)` inclusive, or `None` for "no usable
/// range" — which is a different answer from `Some(None)`, meaning "a range that cannot be
/// satisfied". Multi-range requests are declined rather than honoured: they answer with a multipart
/// body that no client of this site has ever asked for, and returning the whole file is a legal
/// response to one.
fn parse_range(value: &str, total: u64) -> Option<Option<(u64, u64)>> {
    let spec = value.strip_prefix("bytes=")?.trim();
    if spec.contains(',') {
        return None;
    }

    let (first, last) = spec.split_once('-')?;
    let (start, end) = if first.is_empty() {
        // `bytes=-500`: the last five hundred bytes.
        let wanted: u64 = last.trim().parse().ok()?;
        if wanted == 0 || total == 0 {
            return Some(None);
        }
        (total.saturating_sub(wanted), total - 1)
    } else {
        let start: u64 = first.trim().parse().ok()?;
        let end = match last.trim() {
            "" => total.saturating_sub(1),
            last => last.parse().ok()?,
        };
        (start, end.min(total.saturating_sub(1)))
    };

    if total == 0 || start > end || start >= total {
        return Some(None);
    }

    Some(Some((start, end)))
}

/// Takes the response by value because a file body cannot be copied out of a borrow: `AsyncRead` is
/// implemented for `tokio::fs::File` and not for `&tokio::fs::File`, so streaming one means owning
/// it. Nothing downstream needs the response afterwards.
async fn write_response(
    stream: &mut TcpStream,
    response: Response,
    head_only: bool,
    close: bool,
) -> std::io::Result<()> {
    let mut head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\n",
        response.status, response.reason, response.content_type
    );

    // A 304 describes no body at all, so stating a length for it — even zero — would be a claim
    // about a representation that was not sent.
    if response.status != 304 {
        head.push_str(&format!("Content-Length: {}\r\n", response.body.len()));
    }

    for header in &response.extra {
        head.push_str(header);
        head.push_str("\r\n");
    }

    head.push_str(&format!("Cache-Control: {}\r\n", response.cache_control));

    // No inline scripts or styles anywhere on the site, so the policy can be this strict without
    // anything to relax it for. See the note in `styles.css`.
    head.push_str(
        "Content-Security-Policy: default-src 'self'; img-src 'self'; style-src 'self'; \
         script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; \
         frame-ancestors 'none'; object-src 'none'\r\n",
    );
    head.push_str("X-Content-Type-Options: nosniff\r\n");
    head.push_str("Referrer-Policy: strict-origin-when-cross-origin\r\n");
    head.push_str("Permissions-Policy: camera=(), microphone=(), geolocation=(), usb=()\r\n");
    // Sent unconditionally. A browser only honours it over a connection it already trusts, so this
    // is inert when the site is reached over plain HTTP through a proxy that terminates TLS — and
    // it is what keeps the domain on HTTPS once it has been seen over one.
    head.push_str("Strict-Transport-Security: max-age=31536000\r\n");
    head.push_str(if close { "Connection: close\r\n\r\n" } else { "\r\n" });

    stream.write_all(head.as_bytes()).await?;

    if !head_only {
        match response.body {
            Body::Bytes(bytes) => stream.write_all(&bytes).await?,
            // Copied through in chunks rather than read and sent, so nothing larger than the copy
            // buffer is ever held — a disk image is twenty megabytes and the process serving it is
            // also relaying video.
            Body::File { file, len } => {
                let mut source = file.take(len);
                tokio::io::copy(&mut source, stream).await?;
            }
        }
    }

    stream.flush().await
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// Turns a request path into a file under `root`, or `None` if it is not one this server will
/// serve. See the safety rules in the module comment.
fn resolve(root: &Path, path: &str) -> Option<PathBuf> {
    // The one dotted path served: Apple fetches it by this exact name, with no extension.
    if path == APPLE_APP_SITE_ASSOCIATION {
        return Some(root.join(&APPLE_APP_SITE_ASSOCIATION[1..]));
    }

    let decoded = percent_decode(path)?;

    if decoded.contains('\0') || decoded.contains('\\') {
        return None;
    }

    let mut file = root.to_path_buf();
    let mut named = false;

    for component in decoded.split('/') {
        if component.is_empty() {
            continue;
        }
        if component == "." || component == ".." || component.starts_with('.') {
            return None;
        }
        file.push(component);
        named = true;
    }

    if !named {
        file.push("index.html");
    } else if !file.extension().is_some_and(|extension| !extension.is_empty()) {
        // `/privacy` reads better than `/privacy.html` in a store listing and in a legal link, and
        // one line here is cheaper than a redirect or a second set of files.
        file.set_extension("html");
        // `/de` is a folder with an index, not a page called de.html.
        if !file.is_file() {
            let folder_index = file.with_extension("").join("index.html");
            if folder_index.is_file() {
                return Some(folder_index);
            }
        }
    }

    Some(file)
}

/// Percent-decodes a URL path. Invalid escapes are a refusal rather than a pass-through.
fn percent_decode(input: &str) -> Option<String> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        match bytes[index] {
            b'%' => {
                let hex = bytes.get(index + 1..index + 3)?;
                let value = std::str::from_utf8(hex).ok()?;
                out.push(u8::from_str_radix(value, 16).ok()?);
                index += 3;
            }
            byte => {
                out.push(byte);
                index += 1;
            }
        }
    }

    String::from_utf8(out).ok()
}

fn cache_control_for(file: &Path) -> &'static str {
    match file.extension().and_then(|e| e.to_str()) {
        // Hash-stamped by deploy-site.sh and the font URL is versioned by name, so these are safe
        // to hold for a year.
        Some("css" | "js" | "woff2") => "max-age=31536000, immutable",
        // Images change rarely; a week is enough buffer between a deploy and cache expiry.
        Some("webp" | "png" | "svg" | "avif" | "jpg" | "jpeg" | "ico") => "max-age=604800",
        // Everything else — HTML, XML (appcast), DMG — is either user-visible content that should
        // reflect the latest deploy, or a download whose URL is already versioned.
        _ => "no-cache",
    }
}

const APPLE_APP_SITE_ASSOCIATION: &str = "/.well-known/apple-app-site-association";

fn content_type(file: &Path) -> &'static str {
    if file.ends_with(".well-known/apple-app-site-association") {
        return "application/json";
    }
    match file.extension().and_then(|extension| extension.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("json") => "application/json",
        Some("webmanifest") => "application/manifest+json",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("webp") => "image/webp",
        Some("avif") => "image/avif",
        Some("ico") => "image/x-icon",
        Some("woff2") => "font/woff2",
        Some("txt") => "text/plain; charset=utf-8",
        Some("xml") => "application/xml",
        Some("pdf") => "application/pdf",
        _ => "application/octet-stream",
    }
}

/// The IMF-fixdate an HTTP header carries, which is not quite what any date library prints.
fn http_date(time: std::time::SystemTime) -> String {
    const DAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];

    let seconds = time.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);

    // Days since the epoch, and the time of day within the current one. Done with integer
    // arithmetic rather than a calendar library: this is the only date the relay ever formats.
    let days = seconds / 86_400;
    let (hour, minute, second) = {
        let rest = seconds % 86_400;
        (rest / 3600, (rest % 3600) / 60, rest % 60)
    };

    // 1970-01-01 was a Thursday, which is index 4.
    let weekday = ((days + 4) % 7) as usize;

    let (year, month, day) = civil_from_days(days as i64);

    format!(
        "{}, {:02} {} {} {:02}:{:02}:{:02} GMT",
        DAYS[weekday],
        day,
        MONTHS[(month - 1) as usize],
        year,
        hour,
        minute,
        second
    )
}

/// Days since 1970-01-01 to a calendar date. Howard Hinnant's `civil_from_days`, which is exact for
/// every date this will ever be asked about and is nine lines.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Binds the site's listener and says where it is.
///
/// Returns `None` — having said why — when there is no site to serve, so that a relay deployed
/// without one does not hold a port open for nothing.
pub async fn bind(address: std::net::SocketAddr, root: PathBuf) -> Option<(TcpListener, PathBuf)> {
    if !root.is_dir() {
        warn!(
            root = %root.display(),
            "no site directory at PEERINGD_WEB_ROOT, so the site will not be served"
        );
        return None;
    }

    match TcpListener::bind(address).await {
        Ok(listener) => {
            info!(addr = %address, root = %root.display(), "site listening");
            Some((listener, root))
        }
        Err(error) => {
            warn!(%error, %address, "could not bind the site's address");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn healthz_answers_without_touching_the_disk() {
        // The root names nothing at all, so if this ever starts resolving files the test fails
        // rather than passing by accident. That is the property worth pinning: the check has to
        // work when the site directory is missing or unreadable, because "the relay is up" and
        // "the site is deployed" are different questions and a monitor wants the first.
        let response = respond(
            "GET /healthz HTTP/1.1\r\nHost: getpeering.app\r\n",
            Path::new("/nonexistent-site-root"),
        )
        .await;

        assert_eq!(response.status, 200);
        assert!(
            matches!(&response.body, Body::Bytes(bytes) if bytes.starts_with(b"ok peeringd ")),
            "the answer should name the binary and its version"
        );
    }

    #[tokio::test]
    async fn healthz_is_not_reachable_by_a_relative_path() {
        // Only the exact path answers, so nothing that merely *contains* it can be used to probe
        // the process — and a file named healthz in the site root would still be a 404, which is
        // what happens here because the root does not exist.
        let response = respond("GET /healthz/../healthz HTTP/1.1\r\n", Path::new("/nope")).await;
        assert_eq!(response.status, 404);
    }

    #[test]
    fn resolves_plain_paths() {
        let root = Path::new("/srv/site");
        assert_eq!(resolve(root, "/").unwrap(), root.join("index.html"));
        assert_eq!(resolve(root, "/styles.css").unwrap(), root.join("styles.css"));
        assert_eq!(resolve(root, "/assets/x.png").unwrap(), root.join("assets/x.png"));
    }

    #[test]
    fn gives_extensionless_paths_an_html_extension() {
        let root = Path::new("/srv/site");
        assert_eq!(resolve(root, "/privacy").unwrap(), root.join("privacy.html"));
        assert_eq!(resolve(root, "/privacy/").unwrap(), root.join("privacy.html"));
        assert_eq!(resolve(root, "//privacy").unwrap(), root.join("privacy.html"));
    }

    #[test]
    fn serves_a_folder_through_its_index() {
        let root = std::env::temp_dir().join(format!("peeringd-folder-{}", std::process::id()));
        std::fs::create_dir_all(root.join("de")).unwrap();
        std::fs::write(root.join("de/index.html"), "x").unwrap();
        std::fs::write(root.join("privacy.html"), "x").unwrap();
        assert_eq!(resolve(&root, "/de").unwrap(), root.join("de/index.html"));
        assert_eq!(resolve(&root, "/de/").unwrap(), root.join("de/index.html"));
        assert_eq!(resolve(&root, "/privacy").unwrap(), root.join("privacy.html"));
        assert_eq!(resolve(&root, "/missing").unwrap(), root.join("missing.html"));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn serves_the_apple_app_site_association_and_no_other_dotted_path() {
        let root = Path::new("/srv/site");
        let file = resolve(root, "/.well-known/apple-app-site-association").unwrap();
        assert_eq!(file, root.join(".well-known/apple-app-site-association"));
        assert_eq!(content_type(&file), "application/json");
        assert!(resolve(root, "/.well-known/other").is_none());
        assert!(resolve(root, "/.well-known/apple-app-site-association/../../etc").is_none());
    }

    #[test]
    fn refuses_escapes() {
        let root = Path::new("/srv/site");
        assert!(resolve(root, "/../secrets").is_none());
        assert!(resolve(root, "/assets/../../secrets").is_none());
        assert!(resolve(root, "/./x").is_none());
        assert!(resolve(root, "/.env").is_none());
        assert!(resolve(root, "/assets/.hidden").is_none());
        assert!(resolve(root, "/%2e%2e/secrets").is_none());
        assert!(resolve(root, "/..%2fsecrets").is_none());
        assert!(resolve(root, "/x%00y").is_none());
        assert!(resolve(root, "/x\\y").is_none());
        assert!(resolve(root, "/%zz").is_none());
    }

    #[test]
    fn decodes_ordinary_escapes() {
        assert_eq!(percent_decode("/a%20b").unwrap(), "/a b");
        assert_eq!(percent_decode("/caf%C3%A9").unwrap(), "/café");
    }

    #[test]
    fn formats_http_dates() {
        // The example from the HTTP specification, and the epoch itself.
        assert_eq!(http_date(UNIX_EPOCH), "Thu, 01 Jan 1970 00:00:00 GMT");
        assert_eq!(
            http_date(UNIX_EPOCH + Duration::from_secs(784_111_777)),
            "Sun, 06 Nov 1994 08:49:37 GMT"
        );
        assert_eq!(
            http_date(UNIX_EPOCH + Duration::from_secs(1_767_225_600)),
            "Thu, 01 Jan 2026 00:00:00 GMT"
        );
        // A leap day, because the arithmetic above is the kind that is wrong on exactly one day
        // every four years.
        assert_eq!(
            http_date(UNIX_EPOCH + Duration::from_secs(1_709_164_800)),
            "Thu, 29 Feb 2024 00:00:00 GMT"
        );
    }

    #[test]
    fn reads_the_request_line() {
        assert_eq!(request_line("GET / HTTP/1.1\r\n\r\n"), Some(("GET", "/", "HTTP/1.1")));
        assert_eq!(request_line("HEAD /a HTTP/1.0\r\n"), Some(("HEAD", "/a", "HTTP/1.0")));
        assert!(request_line("GET / HTTP/1.1 extra\r\n").is_none());
        assert!(request_line("garbage").is_none());
    }

    #[test]
    fn reads_the_headers_it_cares_about() {
        let head = "GET / HTTP/1.1\r\nHost: x\r\nIf-None-Match: \"abc\"\r\nRange: bytes=0-9\r\n\r\n";
        let headers = request_headers(head);
        assert_eq!(headers.if_none_match.as_deref(), Some("\"abc\""));
        assert_eq!(headers.range.as_deref(), Some("bytes=0-9"));

        let head = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
        let headers = request_headers(head);
        assert!(headers.if_none_match.is_none());
        assert!(headers.range.is_none());
    }

    #[test]
    fn decides_whether_a_connection_stays_open() {
        // HTTP/1.1 keeps it open unless told otherwise; HTTP/1.0 is the other way round.
        assert_eq!(connection_of("GET / HTTP/1.1\r\n\r\n"), Connection::KeepAlive);
        assert_eq!(connection_of("GET / HTTP/1.0\r\n\r\n"), Connection::Close);
        assert_eq!(
            connection_of("GET / HTTP/1.1\r\nConnection: close\r\n\r\n"),
            Connection::Close
        );
        assert_eq!(
            connection_of("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"),
            Connection::KeepAlive
        );
    }

    #[test]
    fn parses_ranges() {
        // A window, an open-ended window, and a suffix.
        assert_eq!(parse_range("bytes=0-99", 1000), Some(Some((0, 99))));
        assert_eq!(parse_range("bytes=500-", 1000), Some(Some((500, 999))));
        assert_eq!(parse_range("bytes=-100", 1000), Some(Some((900, 999))));
        // An end past the file is clamped rather than refused, which is what the spec asks for.
        assert_eq!(parse_range("bytes=900-5000", 1000), Some(Some((900, 999))));
        // Past the end entirely, a backwards window, and a zero-length suffix: unsatisfiable.
        assert_eq!(parse_range("bytes=1000-", 1000), Some(None));
        assert_eq!(parse_range("bytes=50-10", 1000), Some(None));
        assert_eq!(parse_range("bytes=-0", 1000), Some(None));
        // Not a range this server acts on: the whole file is a legal answer to each.
        assert_eq!(parse_range("items=0-10", 1000), None);
        assert_eq!(parse_range("bytes=0-10, 20-30", 1000), None);
        assert_eq!(parse_range("bytes=abc", 1000), None);
        assert_eq!(parse_range("bytes=", 1000), None);
    }

    #[test]
    fn finds_the_end_of_a_head() {
        assert_eq!(find_head_end(b"GET / HTTP/1.1\r\n\r\n"), Some(18));
        assert_eq!(find_head_end(b"GET / HTTP/1.1\r\n"), None);
    }
}
