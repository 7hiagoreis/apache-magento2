vcl 4.1;

import std;

backend default {
    .host = "127.0.0.1";
    .port = "8080";
    .first_byte_timeout = 60s;
    .between_bytes_timeout = 60s;
    .probe = {
        .url = "/pub/health_check.php";
        .timeout = 1s;
        .interval = 5s;
        .window = 10;
        .threshold = 5;
    }
}

acl purge {
    "localhost";
    "127.0.0.1";
    "::1";
}

sub vcl_recv {
    # Otimização radical para TTFB - Cache agressivo
    unset req.http.Cookie;
    unset req.http.Authorization;
    
    # Bypass para URLs administrativas
    if (req.url ~ "^/(admin|checkout|customer|api|rest|graphql|health_check\.php)") {
        return (pass);
    }

    # Normalização de URLs estáticos
    if (req.url ~ "^/static/version\d+/(.*)$") {
        set req.url = regsub(req.url, "^/static/version\d+/", "/static/");
    }

    # Purge logic
    if (req.method == "PURGE") {
        if (client.ip !~ purge) {
            return (synth(405, "Method not allowed"));
        }
        return (purge);
    }

    # Aplicar cache em tudo exceto POST/PUT/DELETE
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    return (hash);
}

sub vcl_backend_response {
    # Configurações agressivas para TTFB baixo
    set beresp.grace = 24h;
    set beresp.keep = 48h;
    
    # Cache extremo para estáticos (1 ano)
    if (bereq.url ~ "^/(pub/)?(media|static)/") {
        set beresp.ttl = 1y;
        set beresp.http.Cache-Control = "public, max-age=31536000, immutable";
        unset beresp.http.Set-Cookie;
        set beresp.do_gzip = true;
    }
    # Cache para conteúdo dinâmico (30 minutos)
    else {
        set beresp.ttl = 30m;
        set beresp.http.Cache-Control = "public, max-age=1800";
    }
    
    # Ignorar cookies completamente
    unset beresp.http.Set-Cookie;
}

sub vcl_deliver {
    # Headers de debug
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
        set resp.http.X-Cache-TTL = obj.ttl;
    } else {
        set resp.http.X-Cache = "MISS";
    }
    
    # Headers de performance
    set resp.http.X-Edge-Performance = "Magento2-Varnish-1.0";
    
    # Remoção completa de headers desnecessários
    unset resp.http.Server;
    unset resp.http.X-Powered-By;
    unset resp.http.X-Varnish;
    unset resp.http.Via;
    unset resp.http.Link;
    unset resp.http.ETag;
}

sub vcl_hit {
    if (obj.ttl >= 0s) {
        return (deliver);
    }
    
    if (std.healthy(req.backend_hint)) {
        if (obj.ttl + 10s > 0s) {
            return (deliver);
        } else {
            return (fetch);
        }
    } else {
        if (obj.ttl + obj.grace > 0s) {
            return (deliver);
        } else {
            return (fetch);
        }
    }
}

sub vcl_miss {
    return (fetch);
}
