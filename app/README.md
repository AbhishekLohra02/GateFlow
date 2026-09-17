# app/

The application GateFlow deploys. Deliberately simple (Flask, 2 routes) -
it exists to give the pipeline something real to build, test, and ship;
it is not the point of this project, the pipeline around it is.

- `app.py` - the app (Flask, served by gunicorn in the container)
- `requirements.txt` - dependency manifest
- `Dockerfile` - multi-stage build; see the walkthrough notes for why each
  line is there (layer caching via requirements.txt-first, non-root user,
  slim base, gunicorn instead of Flask's dev server)
