-module(rabbit_trust_store_certificate_provider).

-include_lib("public_key/include/public_key.hrl").

-callback list_certs(Config)
    -> no_change | {ok, [{CertId, Attributes}]}
    when Config :: list(),
         CertId :: term(),
         Attributes :: map().

-callback list_certs(Config, ProviderState)
    -> no_change | {ok, [{CertId, Attributes}]}
    when Config :: list(),
         ProviderState :: term(),
         CertId :: term(),
         Attributes :: map().

-callback get_cert_data(CertId, Attributes, Config)
    -> {ok, Cert} | {error, term()}
    when CertId :: term(),
         Attributes :: map(),
         Config :: list(),
         Cert :: public_key:der_encoded().