-module(sekisho_crypto).
-moduledoc """
Authenticated encryption for provider credentials at rest (AES-256-GCM).

The 32-byte master key comes from the `SEKISHO_MASTER_KEY` environment variable,
base16- or base64-encoded. Ciphertext is stored as `nonce(12) || tag(16) ||
ciphertext`. Plaintext credentials exist only transiently in memory; this module
never logs them.
""".

-export([encrypt/1, decrypt/1, master_key/0]).

-define(NONCE_BYTES, 12).
-define(TAG_BYTES, 16).
-define(KEY_BYTES, 32).

-doc "Encrypt plaintext into `nonce || tag || ciphertext`.".
-spec encrypt(binary()) -> binary().
encrypt(Plaintext) when is_binary(Plaintext) ->
    Key = master_key(),
    Nonce = crypto:strong_rand_bytes(?NONCE_BYTES),
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm, Key, Nonce, Plaintext, <<>>, ?TAG_BYTES, true
    ),
    <<Nonce/binary, Tag/binary, Ciphertext/binary>>.

-doc "Decrypt a `nonce || tag || ciphertext` blob. Fails on a bad tag.".
-spec decrypt(binary()) -> binary().
decrypt(<<Nonce:?NONCE_BYTES/binary, Tag:?TAG_BYTES/binary, Ciphertext/binary>>) ->
    Key = master_key(),
    case crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Ciphertext, <<>>, Tag, false) of
        error -> error(decrypt_failed);
        Plaintext -> Plaintext
    end.

-doc "The 32-byte master key from `SEKISHO_MASTER_KEY` (base16 or base64).".
-spec master_key() -> binary().
master_key() ->
    case os:getenv("SEKISHO_MASTER_KEY") of
        false -> error(missing_master_key);
        Raw -> decode_key(list_to_binary(Raw))
    end.

decode_key(Raw) ->
    case try_base16(Raw) of
        {ok, <<Key:?KEY_BYTES/binary>>} -> Key;
        _ -> decode_base64(Raw)
    end.

try_base16(Raw) ->
    try
        {ok, binary:decode_hex(Raw)}
    catch
        _:_ -> error
    end.

decode_base64(Raw) ->
    case base64:decode(Raw, #{padding => false}) of
        <<Key:?KEY_BYTES/binary>> -> Key;
        _ -> error(invalid_master_key)
    end.
