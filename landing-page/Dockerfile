FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./
COPY static ./static
ENV FLASK_APP=app.py
ENV PORT=8080
CMD ["flask", "run", "--host=0.0.0.0", "--port=8080"]
