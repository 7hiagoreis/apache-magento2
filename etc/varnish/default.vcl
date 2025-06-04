# A versão 5.0 do VCL não é suportada, então deve ser 4.0 mesmo que a versão real do Varnish seja 6
vcl 4.0;

import std;
# A versão mínima do Varnish é 6.0
# Para descarregamento SSL, passe o seguinte cabeçalho no seu proxy ou balanceador: 'X-Forwarded-Proto: https'

backend default {
    .host = "<seu_endereço_IP>";
    .port = "8080";
    .first_byte_timeout = 600s;
    .probe = {
        .url = "/health_check.php";
        .timeout = 2s;
        .interval = 5s;
        .window = 10;
        .threshold = 5;
   }
}

acl purge {
    "localhost";
}

sub vcl_recv {
    if (req.restarts > 0) {
        set req.hash_always_miss = true;
    }

    if (req.method == "PURGE") {
        if (client.ip !~ purge) {
            return (synth(405, "Método não permitido"));
        }
        # Para usar o cabeçalho X-Pool para purga automática durante deploys,
        # certifique-se de que o cabeçalho X-Pool foi adicionado na resposta do backend.
        # Isso é usado, por exemplo, pelo gem capistrano-magento2 para limpar conteúdo antigo do varnish durante o deploy.
        if (!req.http.X-Magento-Tags-Pattern && !req.http.X-Pool) {
            return (synth(400, "Cabeçalho X-Magento-Tags-Pattern ou X-Pool obrigatório"));
        }
        if (req.http.X-Magento-Tags-Pattern) {
          ban("obj.http.X-Magento-Tags ~ " + req.http.X-Magento-Tags-Pattern);
        }
        if (req.http.X-Pool) {
          ban("obj.http.X-Pool ~ " + req.http.X-Pool);
        }
        return (synth(200, "Purgado"));
    }

    if (req.method != "GET" &&
        req.method != "HEAD" &&
        req.method != "PUT" &&
        req.method != "POST" &&
        req.method != "TRACE" &&
        req.method != "OPTIONS" &&
        req.method != "DELETE") {
          /* Método não RFC2616 ou CONNECT, o que é estranho. */
          return (pipe);
    }

    # Lidando somente com GET e HEAD por padrão
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    # Ignorar URLs de cliente, carrinho e checkout
    if (req.url ~ "/customer" || req.url ~ "/checkout") {
        return (pass);
    }

    # Ignorar requisições de health check
    if (req.url ~ "^/(pub/)?(health_check.php)$") {
        return (pass);
    }

    # Define o status inicial do uso do grace period
    set req.http.grace = "none";

    # Normaliza a URL, removendo esquema HTTP(s) e domínio no começo
    set req.url = regsub(req.url, "^http[s]?://", "");

    # Coleta todos os cookies
    std.collect(req.http.Cookie);

    # Remove parâmetros GET de marketing para minimizar objetos em cache
    if (req.url ~ "(\?|&)(gclid|cx|ie|cof|siteurl|zanpid|origin|fbclid|mc_[a-z]+|utm_[a-z]+|_bta_[a-z]+)=") {
        set req.url = regsuball(req.url, "(gclid|cx|ie|cof|siteurl|zanpid|origin|fbclid|mc_[a-z]+|utm_[a-z]+|_bta_[a-z]+)=[-_A-z0-9+()%.]+&?", "");
        set req.url = regsub(req.url, "[?|&]+$", "");
    }

    # Cache para arquivos estáticos
    if (req.url ~ "^/(pub/)?(media|static)/") {
        # Arquivos estáticos não devem ser cacheados por padrão
        return (pass);

        # Mas se você usa poucos locais e não usa CDN, pode habilitar o cache removendo o return acima e descomentando as próximas linhas:
        #unset req.http.Https;
        #unset req.http.X-Forwarded-Proto;
        #unset req.http.Cookie;
    }

    # Ignorar requisições autenticadas GraphQL sem X-Magento-Cache-Id
    if (req.url ~ "/graphql" && !req.http.X-Magento-Cache-Id && req.http.Authorization ~ "^Bearer") {
        return (pass);
    }

    return (hash);
}

sub vcl_hash {
    if ((req.url !~ "/graphql" || !req.http.X-Magento-Cache-Id) && req.http.cookie ~ "X-Magento-Vary=") {
        hash_data(regsub(req.http.cookie, "^.*?X-Magento-Vary=([^;]+);*.*$", "\1"));
    }

    # Para garantir que usuários HTTP não vejam aviso SSL
    if (req.http.X-Forwarded-Proto) {
        hash_data(req.http.X-Forwarded-Proto);
    }
    

    if (req.url ~ "/graphql") {
        call process_graphql_headers;
    }
}

sub process_graphql_headers {
    if (req.http.X-Magento-Cache-Id) {
        hash_data(req.http.X-Magento-Cache-Id);

        # Quando o frontend parar de enviar o token de autenticação,
        # garanta que usuários parem de receber resultados de cache para usuários conectados
        if (req.http.Authorization ~ "^Bearer") {
            hash_data("Authorized");
        }
    }

    if (req.http.Store) {
        hash_data(req.http.Store);
    }

    if (req.http.Content-Currency) {
        hash_data(req.http.Content-Currency);
    }
}

sub vcl_backend_response {

    set beresp.grace = 3d;

    if (beresp.http.content-type ~ "text") {
        set beresp.do_esi = true;
    }

    if (bereq.url ~ "\.js$" || beresp.http.content-type ~ "text") {
        set beresp.do_gzip = true;
    }

    if (beresp.http.X-Magento-Debug) {
        set beresp.http.X-Magento-Cache-Control = beresp.http.Cache-Control;
    }

    # Fazer cache apenas das respostas de sucesso e 404 que não estão marcadas como privadas
    if ((beresp.status != 200 && beresp.status != 404) || beresp.http.Cache-Control ~ "private") {
        set beresp.uncacheable = true;
        set beresp.ttl = 86400s;
        return (deliver);
    }

    # Valida se precisamos cachear e impede de definir cookie
    if (beresp.ttl > 0s && (bereq.method == "GET" || bereq.method == "HEAD")) {
        # Colapsa beresp.http.set-cookie para juntar múltiplos cabeçalhos set-cookie
        # Embora não seja recomendado colapsar set-cookie, aqui é seguro pois set-cookie será removido abaixo
        std.collect(beresp.http.set-cookie);
        # Não cacheia a resposta na chave atual (hash),
        # se a resposta tem X-Magento-Vary mas a requisição não.
        if ((bereq.url !~ "/graphql" || !bereq.http.X-Magento-Cache-Id)
         && bereq.http.cookie !~ "X-Magento-Vary="
         && beresp.http.set-cookie ~ "X-Magento-Vary=") {
           set beresp.ttl = 0s;
           set beresp.uncacheable = true;
        }
        unset beresp.http.set-cookie;
    }

    # Se a página não for possivel fazer o cache da página, ignorar o varnish por 2 minutos (Hit-For-Pass)
    if (beresp.ttl <= 0s ||
        beresp.http.Surrogate-control ~ "no-store" ||
        (!beresp.http.Surrogate-Control &&
        beresp.http.Cache-Control ~ "no-cache|no-store") ||
        beresp.http.Vary == "*") {
        # Marca como Hit-For-Pass pelos próximos 2 minutos
        set beresp.ttl = 120s;
        set beresp.uncacheable = true;
    }

    # Se a chave do cache na resposta do Magento não bater com a da requisição, não faz o cache na chave da requisição
    if (bereq.url ~ "/graphql" && bereq.http.X-Magento-Cache-Id && bereq.http.X-Magento-Cache-Id != beresp.http.X-Magento-Cache-Id) {
        set beresp.ttl = 0s;
        set beresp.uncacheable = true;
    }

    return (deliver);
}

sub vcl_deliver {
    if (obj.uncacheable) {
        set resp.http.X-Magento-Cache-Debug = "UNCACHEABLE";
    } else if (obj.hits) {
        set resp.http.X-Magento-Cache-Debug = "HIT";
        set resp.http.Grace = req.http.grace;
    } else {
        set resp.http.X-Magento-Cache-Debug = "MISS";
    }

    # Não permitir que o navegador faça cache de arquivos não estáticos.
    if (resp.http.Cache-Control !~ "private" && req.url !~ "^/(pub/)?(media|static)/") {
        set resp.http.Pragma = "no-cache";
        set resp.http.Expires = "-1";
        set resp.http.Cache-Control = "no-store, no-cache, must-revalidate,
