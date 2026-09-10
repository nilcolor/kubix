#!/bin/sh
# Synthetic local protocol fixture. No startup files, browser, network, or real credentials.
credential() {
    printf '%s' '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"synthetic-credential-only"}}'
}
if [ "$1" = "--version" ]; then
    printf 'aws-cli/2.99.0 synthetic\n'
    exit 0
fi
if [ "$1" = "sso" ] && [ "$2" = "login" ]; then
    [ "$AWS_PAGER" = "" ] && [ "$AWS_CLI_AUTO_PROMPT" = "off" ] || exit 81
    [ -z "$KUBERNETES_EXEC_INFO" ] || exit 82
    printf 'https://synthetic.invalid/authorize?code=synthetic-login\n'
    printf 'Device code: SYNTHETIC-CODE' >&2
    case "$STUB_MODE" in
        login-wait) IFS= read -r answer < "$STUB_GATE";;
        login-fail) exit 23;;
    esac
    exit 0
fi
if IFS= read -r unexpected; then exit 83; fi
case "$KUBERNETES_EXEC_INFO" in
    *'"interactive":false'*) ;;
    *) exit 84;;
esac
case "$STUB_MODE" in
    prompt)
        printf '\342\202\254 Open https://synthetic.invalid/authorize' >&2
        IFS= read -r answer < "$STUB_GATE"
        credential;;
    pressure)
        credential
        index=0
        while [ "$index" -lt 12000 ]; do
            printf 'synthetic stderr pressure 012345678901234567890123456789012345678901234567890123456789\n' >&2
            index=$((index + 1))
        done;;
    overflow)
        index=0
        while [ "$index" -lt 16000 ]; do
            printf 'synthetic stdout overflow 012345678901234567890123456789012345678901234567890123456789\n'
            index=$((index + 1))
        done;;
    wait)
        printf 'waiting without newline' >&2
        IFS= read -r answer < "$STUB_GATE"
        credential;;
    inherited-pipe)
        /bin/sleep 30 &
        printf '%s' "$!" >&2
        credential;;
    nonzero) printf 'synthetic-credential-only'; exit 17;;
    malformed) printf 'not-json synthetic-credential-only';;
    mismatch) printf '%s' '{"apiVersion":"client.authentication.k8s.io/v1beta1","kind":"ExecCredential","status":{"token":"synthetic-credential-only"}}';;
    expired) printf '%s' '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"synthetic-credential-only","expirationTimestamp":"2000-01-01T00:00:00Z"}}';;
    certificates) printf '%s' '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"clientCertificateData":"synthetic-cert","clientKeyData":"synthetic-key"}}';;
    arguments)
        [ "$1" = 'space ; $(not-a-command)' ] || exit 85
        [ "$FIXTURE_VALUE" = "kubeconfig" ] || exit 86
        credential;;
    *) credential;;
esac
