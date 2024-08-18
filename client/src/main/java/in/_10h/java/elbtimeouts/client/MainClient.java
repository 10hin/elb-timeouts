package in._10h.java.elbtimeouts.client;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;

public class MainClient {
    public static void main(final String[] args) {
        // System.setProperty("jdk.httpclient.keepalive.timeout", "30");
        final var clientBuilder = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .version(HttpClient.Version.HTTP_1_1)
                .followRedirects(HttpClient.Redirect.NEVER);
        final HttpClient client = clientBuilder.build();

        for (var i = 0; i < 2; i++) {
            final var request = HttpRequest.newBuilder()
                    .GET()
                    .uri(URI.create("http://localhost/test" + i))
                    .build();
            try {
                final var resp = client.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            } catch (IOException e) {
                throw new RuntimeException("Unexpected I/O exception happened", e);
            } catch (InterruptedException e) {
                throw new InternalError("interrupted", e);
            }
        }
    }
}
