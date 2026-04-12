# OpenFaaS Build Context Templates

These directories contain the OpenFaaS template files used to build the function container images.
They were generated on the master node (`golgi-master`) by `faas-cli build --shrinkwrap` and
`faas-cli template store pull`, then copied here for version control.

## How the build works

When you run `faas-cli build --shrinkwrap`, it:
1. Copies the template files (Dockerfile, index.py/main.go, etc.) into a build context
2. Copies your function handler code into `function/` within that context
3. The Dockerfile then builds the image with the watchdog + your handler

The actual function handler code lives in `functions/` at the repo root. These template files
are the scaffolding that wraps handlers into runnable containers.

## Directory structure

```
build/
  python3-http/       # Template for image-resize and db-query (Python functions)
    Dockerfile        # Multi-stage: watchdog + python + flask/waitress + handler
    index.py          # Flask WSGI server that routes requests to handler.handle()
    requirements.txt  # Template-level deps: flask, waitress, tox
    template.yml      # OpenFaaS template metadata
  golang-http/        # Template for log-filter (Go function)
    Dockerfile        # Multi-stage: watchdog + go build + alpine runtime
    main.go           # HTTP server that routes requests to function.Handle()
    go.mod            # Go module definition with OpenFaaS SDK dependency
    go.sum            # Go module checksums
    modules-cleanup.sh # Script that restructures go.mod for the build context
    template.yml      # OpenFaaS template metadata
```

## Template sources

- `python3-http`: https://github.com/openfaas/python-flask-template (tag: of-watchdog 0.11.5)
- `golang-http`: https://github.com/openfaas/golang-http-template (commit 75e11a7)

## Rebuilding images

To rebuild images from scratch on the master node:
```bash
faas-cli template store pull python3-http
faas-cli template store pull golang-http
faas-cli build --shrinkwrap -f stack.yml
cd build/<function> && docker build -t golgi/<function>:v1.0 .
```
