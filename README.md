# Python Runner

Docker container that clones a GitHub repository containing a Python web application, installs dependencies, and runs the application.

---
<div align="center">

## Quick Demo: Open Source Cloud

Run this service in the cloud with a single click.

[![Badge OSC](https://img.shields.io/badge/Try%20it%20out!-1E3A8A?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iMTIiIGZpbGw9InVybCgjcGFpbnQwX2xpbmVhcl8yODIxXzMxNjcyKSIvPgo8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSI3IiBzdHJva2U9ImJsYWNrIiBzdHJva2Utd2lkdGg9IjIiLz4KPGRlZnM+CjxsaW5lYXJHcmFkaWVudCBpZD0icGFpbnQwX2xpbmVhcl8yODIxXzMxNjcyIiB4MT0iMTIiIHkxPSIwIiB4Mj0iMTIiIHkyPSIyNCIgZ3JhZGllbnRVbml0cz0idXNlclNwYWNlT25Vc2UiPgo8c3RvcCBzdG9wLWNvbG9yPSIjQzE4M0ZGIi8+CjxzdG9wIG9mZnNldD0iMSIgc3RvcC1jb2xvcj0iIzREQzlGRiIvPgo8L2xpbmVhckdyYWRpZW50Pgo8L2RlZnM+Cjwvc3ZnPgo=)](https://app.osaas.io/browse/eyevinn-python-runner)

</div>

---

## Usage

### From GitHub

```bash
docker run --rm \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  -e GITHUB_TOKEN=<token> \
  -p 8080:8080 \
  eyevinn/python-runner
```

### From S3 / MinIO

First, zip your project directory:

```bash
cd my-python-app && zip -r ../my-app.zip .
```

Upload the zip file to your S3 bucket, then run:

```bash
docker run --rm \
  -e SOURCE_URL=s3://bucket/my-app.zip \
  -e S3_ENDPOINT_URL=http://minio:9000 \
  -e AWS_ACCESS_KEY_ID=<access-key> \
  -e AWS_SECRET_ACCESS_KEY=<secret-key> \
  -p 8080:8080 \
  eyevinn/python-runner
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `GITHUB_URL` | GitHub repository URL (e.g., `https://github.com/org/repo/`) |
| `GITHUB_TOKEN` | GitHub personal access token for private repositories |
| `SOURCE_URL` | S3 URL to a zipped application (e.g., `s3://bucket/app.zip`) |
| `S3_ENDPOINT_URL` | Custom S3 endpoint URL (for MinIO or other S3-compatible services) |
| `AWS_ACCESS_KEY_ID` | AWS/S3 access key ID |
| `AWS_SECRET_ACCESS_KEY` | AWS/S3 secret access key |
| `OSC_ACCESS_TOKEN` | Access token for Eyevinn Open Source Cloud config service |
| `OSC_REFRESH_TOKEN` | Set by the runner to the original long-lived `OSC_ACCESS_TOKEN` (unless already set). Exchange it for a 1 hour token with `POST https://token.svc.<env>.osaas.io/runner-token/refresh` and body `{"token": "<OSC_REFRESH_TOKEN>"}`; the response field `token` is the new token. A parameter store key with the same name overrides it. Example: `requests.post(f"https://token.svc.{env}.osaas.io/runner-token/refresh", json={"token": os.environ["OSC_REFRESH_TOKEN"]}).json()["token"]` |
| `CONFIG_API_KEY` | Optional API key for encrypted parameter store. When set alongside `OSC_ACCESS_TOKEN` and `CONFIG_SVC`, secret parameters are decrypted before being injected as environment variables. |
| `CONFIG_SVC` | URL to config service endpoint |
| `PORT` | Port to run the application on (default: `8080`) |

## Supported Project Structures

The runner automatically detects and installs dependencies from:

- `pyproject.toml` - Modern Python packaging (PEP 517/518)
- `requirements.txt` - Traditional pip requirements file
- `setup.py` - Legacy setuptools configuration

If a `setup.sh` script is present in the repository root, it will be executed after dependency installation.

## Automatic Framework Detection

The runner automatically detects your application type and starts it with the appropriate server:

| Framework | Detection | Server Used |
|-----------|-----------|-------------|
| **FastAPI/Starlette** | `fastapi` or `starlette` in dependencies | `uvicorn` |
| **Flask** | `flask` in dependencies | `gunicorn` (if available) or `flask run` |
| **Gunicorn** | `gunicorn` in dependencies + config file | `gunicorn` with config |
| **Plain Python** | `main.py` or `app.py` present | `python main.py` |

The runner looks for the app object in common entry point files (`main.py`, `app.py`, `application.py`, `server.py`, `api.py`) and detects common patterns like `app = FastAPI()` or `app = Flask(__name__)`.

## Custom Command

You can override the auto-detection by passing a custom command:

```bash
docker run --rm \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  -p 8080:8080 \
  eyevinn/python-runner \
  python app.py
```

Or for a specific Flask configuration:

```bash
docker run --rm \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  -p 8080:8080 \
  eyevinn/python-runner \
  flask run --host=0.0.0.0 --port=8080
```

Or for Gunicorn with specific options:

```bash
docker run --rm \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  -p 8080:8080 \
  eyevinn/python-runner \
  gunicorn -w 4 -b 0.0.0.0:8080 main:app
```

## Building

```bash
docker build -t eyevinn/python-runner .
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## About Eyevinn Technology

[Eyevinn Technology](https://www.eyevinntechnology.se) is an independent consultant firm specialized in video and streaming. We assist companies with their streaming and cloud strategies, including architecture design and implementation.

In addition to consulting services, we offer cloud-based products like the [Eyevinn Open Source Cloud](https://www.osaas.io) platform - a fully managed solution to launch open-source products in AWS infrastructure.

### Contact

- **Web**: https://www.eyevinntechnology.se
- **Community**: Join our Slack community [here](https://slack.osaas.io)
