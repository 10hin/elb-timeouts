package in._10h.java.elbtimeouts.server;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.Map.Entry;
import java.util.stream.Collectors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;

public class MainServer {
    private static final Logger LOGGER = LoggerFactory.getLogger(MainServer.class.getName());
    private static final String CONNECTION_ID_MDC_KEY = "connID";
    private static final String REQUEST_ID_MDC_KEY = "reqID";
    private static final int WAIT_SECONDS_BEFORE_RESPONSE;
    static {
        WAIT_SECONDS_BEFORE_RESPONSE = Integer.parseInt(System.getProperty("in.10h.java.elbtimeouts.server.waitsecondsbeforeresponse", "0"));
    }

    public static void main(final String[] args) throws IOException {
        try (final var serverSocket = new ServerSocket()) {
            serverSocket.bind(new InetSocketAddress("0.0.0.0", 80));
            while (true) {
                try (final var tcpConnection = serverSocket.accept()) {

                    final var connectionID = UUID.randomUUID();
                    MDC.put(CONNECTION_ID_MDC_KEY, connectionID.toString());
                    try {
                        LOGGER.info("Connection accepted");
                        handleTCPConnection(connectionID, tcpConnection);
                    } catch (final IOException ex) {
                        LOGGER.warn("コネクションの処理がIOExceptionで終了しました。コネクションをクローズして新たな接続を処理します。");
                    } finally {
                        MDC.remove(CONNECTION_ID_MDC_KEY);
                    }

                }
            }
        }
    }

    private static void handleTCPConnection(
        final UUID connectionID,
        final Socket tcpConnection
    ) throws IOException {

        try (final var input = tcpConnection.getInputStream(); final var output = tcpConnection.getOutputStream()) {
            boolean connectionClose = false;

            while (!connectionClose) {

                final ConnectionStatusAfterRequest status;

                final var requestID = UUID.randomUUID();
                MDC.put(REQUEST_ID_MDC_KEY, requestID.toString());
                try {
                    LOGGER.info("Request started");
                    status = handleRequest(connectionID, requestID, input, output);
                    if (status.equals(ConnectionStatusAfterRequest.CLOSE)) {
                        connectionClose = true;
                    }
                } catch (ConnectionAlreadyClosedException e) {
                    LOGGER.info("TCPコネクションは前のリクエストの終了後クライアントによって閉じられました");
                    connectionClose = true;
                } finally {
                    MDC.remove(REQUEST_ID_MDC_KEY);
                }

                if (tcpConnection.isClosed()) {
                    connectionClose = true;
                }

            }

        }

    }

    private enum ConnectionStatusAfterRequest {
        KEEP_ALIVE,
        CLOSE,
        ;
    }

    private static class ConnectionAlreadyClosedException extends Exception {
        ConnectionAlreadyClosedException(final String message, final Throwable cause) {
            super(message, cause);
        }
        protected ConnectionAlreadyClosedException(final String message, final Throwable cause, final boolean enableSuppression, final boolean writableStackTrace) {
            super(message, cause, enableSuppression, writableStackTrace);
        }
    }

    private static ConnectionStatusAfterRequest handleRequest(
        final UUID connectionID,
        final UUID requestID,
        final InputStream input,
        final OutputStream output
    ) throws IOException, ConnectionAlreadyClosedException {

        final RequestLineInfo requestLineInfo;
        try {
            requestLineInfo = readRequestLine(connectionID, requestID, input);
        } catch (EOFBeforeReadException ex) {
            throw new ConnectionAlreadyClosedException("コネクションはリクエストラインが読まれる前に閉じられました", ex);
        }

        final Map<String, List<String>> headers = readRequestHeaders(connectionID, requestID, input);

        final var contentLength = extractContentLengthHeader(connectionID, requestID, headers);

        final var requestBody = readRequestBody(connectionID, requestID, input, contentLength);

        LOGGER.info(new RequestInfo(requestLineInfo, headers, requestBody).dump());

        try {
            LOGGER.info("start wait before response");
            Thread.sleep(WAIT_SECONDS_BEFORE_RESPONSE * 1_000L);
            LOGGER.info("end wait and start response");
        } catch (InterruptedException e) {
            throw new InternalError(e);
        }
        writeResponse(connectionID, requestID, output, 200, "OK", "text/plain", "Hello, world!");

        if (headers.containsKey("connection") && headers.get("connection").size() == 1 && "close".equals(headers.get("connection").get(0))) {
            return ConnectionStatusAfterRequest.CLOSE;
        }
        return ConnectionStatusAfterRequest.KEEP_ALIVE;

    }

    private record RequestLineInfo(String method, String uri) {}

    private static RequestLineInfo readRequestLine(
        final UUID connectionID,
        final UUID requestID,
        final InputStream input
    ) throws IOException, EOFBeforeReadException {

        final var requestLineRaw = readUntilCRLF(input);
        final var requestLine = new String(requestLineRaw, StandardCharsets.UTF_8);
        LOGGER.info("request line read: " + requestLine);
        final var requestLineComponents = requestLine.split(" ");
        if (requestLineComponents.length != 3) {
            throw new IllegalStateException("リクエストラインが空白区切りで区切って3つではありませんでした");
        }
        final var method = requestLineComponents[0];
        final var uri = requestLineComponents[1];
        final var protocolVersion = requestLineComponents[2].stripTrailing();
        if (!"HTTP/1.1".equals(protocolVersion)) {
            throw new IllegalArgumentException("HTTPバージョンが想定されない値です: " + protocolVersion);
        }

        return new RequestLineInfo(method, uri);

    }

    private static Map<String, List<String>> readRequestHeaders(
        final UUID connectionID,
        final UUID requestID,
        final InputStream input
    ) throws IOException {

        final var headersBase = new HashMap<String, List<String>>();
        byte[] raw = null;
        try {
            raw = readUntilCRLF(input);
        } catch (EOFBeforeReadException e) {
            throw new IllegalStateException("コネクションがヘッダーもヘッダー終了区切りも読まれる前に閉じられました", e);
        }
        var lastLine = new String(raw, StandardCharsets.UTF_8); // １行ごとにStringをnewするのは効率悪そう
        /* lastLineは必ずCRLFを含むので、空行はlength() == 2 */
        while (lastLine.length() > 2) {
            LOGGER.info("header line read: " + lastLine);
            final var lastLineComponents = lastLine.split(":", 2);
            final var headerKey = lastLineComponents[0].toLowerCase();
            final var headerValue = lastLineComponents[1].substring(0, lastLineComponents[1].length() - 2); // trim last CRLF
            headersBase.compute(headerKey, (key, currentList) -> {
                if (currentList == null) {
                    final var newList = new ArrayList<String>();
                    newList.add(headerValue);
                    return newList;
                } else {
                    currentList.add(headerValue);
                    return currentList;
                }
            });

            try {
                raw = readUntilCRLF(input);
            } catch (EOFBeforeReadException e) {
                throw new IllegalStateException("コネクションがヘッダー終了区切りを読む前に終了しました", e);
            }
            lastLine = new String(raw, StandardCharsets.UTF_8); // １行ごとにStringをnewするのは効率悪そう
        }
        return headersBase.entrySet()
                .stream()
                .map(entry -> Map.entry(entry.getKey(), List.copyOf(entry.getValue())))
                .collect(Collectors.toMap(Entry::getKey, Entry::getValue));

    }

    private record RequestInfo(RequestLineInfo requestLineInfo, Map<String, List<String>> headers, byte[] body) {
        public String dump() {
            final var builder = new StringBuilder();
            builder.append(this.requestLineInfo.method());
            builder.append(" ");
            builder.append(this.requestLineInfo.uri());
            builder.append(" ");
            builder.append("HTTP/1.1");
            builder.append(System.lineSeparator());
            for (final var entry : this.headers.entrySet()) {
                for (final var value : entry.getValue()) {
                    builder.append(entry.getKey());
                    builder.append(":");
                    builder.append(value);
                    builder.append(System.lineSeparator());
                }
            }
            builder.append(System.lineSeparator());
            builder.append(new String(this.body, StandardCharsets.UTF_8));
            return builder.toString();
        }
    }

    private static int extractContentLengthHeader(
        final UUID connectionID,
        final UUID requestID,
        final Map<String, List<String>> headers
    ) throws IOException {

        final var contentLengthHeaders = headers.getOrDefault("content-length", Collections.emptyList());
        if (contentLengthHeaders.isEmpty()) {
            return 0;
        }
        try {
            return Integer.parseInt(contentLengthHeaders.get(0).trim());
        } catch (final RuntimeException e) {
            throw new IllegalArgumentException("Content-Typeヘッダーの値が不正です: " + contentLengthHeaders.get(0), e);
        }

    }

    private static byte[] readRequestBody(
        final UUID connectionID,
        final UUID requestID,
        final InputStream input,
        final int contentLength
    ) throws IOException {

        final var body = input.readNBytes(contentLength);

        if (body.length < contentLength) {
            throw new IllegalStateException("読み取れたHTTP本文がContent-Lengthヘッダーの値より短い");
        }
        return body;

    }

    private static void writeResponse(
        final UUID connectionID,
        final UUID requestID,
        final OutputStream output,
        final int statusCode,
        final String reasonPhrase,
        final String contentType,
        final String body
    ) throws IOException {

        final var rawBody = body.getBytes(StandardCharsets.UTF_8);
        output.write(("HTTP/1.1 " + statusCode + " " + reasonPhrase + "\r\n").getBytes(StandardCharsets.US_ASCII));
        output.write(("Content-Type:" + contentType + "\r\n").getBytes(StandardCharsets.US_ASCII));
        if (rawBody.length > 0) {
            output.write(("Content-Length:"+rawBody.length+"\r\n").getBytes(StandardCharsets.US_ASCII));
        }
        output.write(0x0D);
        output.write(0x0A);
        if (rawBody.length > 0) {
            output.write(rawBody);
        }

    }

    private static class EOFBeforeReadException extends Exception {
        EOFBeforeReadException(final String message, final Throwable cause) {
            super(message, cause);
        }
        protected EOFBeforeReadException(final String message, final Throwable cause, final boolean enableSuppression, final boolean writableStackTrace) {
            super(message, cause, enableSuppression, writableStackTrace);
        }
    }

    private static byte[] readUntilCRLF(final InputStream input) throws EOFBeforeReadException, IOException {
        final var buffer = new ByteArrayOutputStream(); // １行ごとにnewするのは効率悪そう
        var last = Integer.MAX_VALUE; // while句の中に入れれば何でもよい、使わない値。
        var secondLast = Integer.MAX_VALUE; // while句の中に入れれば何でもよい、使わない値。
        while (secondLast != 0x0D || last != 0x0A) {
            secondLast = last;
            last = input.read();
            if (last == -1) {
                if (buffer.toByteArray().length == 0) {
                    throw new EOFBeforeReadException("読み取る前にStreamはEOFに到達していました", null);
                } else {
                    throw new IllegalStateException("CRLFで区切られることが期待されるタイミングでCRLFが出現するより先に入力チャンネルがEOFになりました");
                }
            }
            buffer.write(last);
        }
        return buffer.toByteArray();
    }

}
