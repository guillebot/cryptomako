# Fixtures

Create a format-8 Cryptomator vault with `cryptomako fixture` (or the desktop app), then copy the ciphertext to S3.

Tree inside the unlocked vault:

```
hello.txt
notes/todo.md
bin/tiny.png
café résumé.txt
nnn…180….txt     # forces .c9s shortening
```

Store the vault password only in gitignored `fixtures/PASSWORD`.

```bash
export CRYPTOMAKO_PASSWORD="$(tr -d '\n' < fixtures/PASSWORD)"
swift run cryptomako ls --local fixtures/vault --path / --recursive
swift run cryptomako cat --local fixtures/vault /hello.txt
```
