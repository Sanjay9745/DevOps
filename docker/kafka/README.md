# Kafka and Zookeeper Docker Setup

This project provides a simple setup for running Apache Kafka and Zookeeper using Docker. It also includes a Kafka UI for easy management and monitoring of Kafka topics and messages.

## Project Structure

```
kafka-docker-project
├── docker-compose.yml
└── README.md
```

## Prerequisites

- Docker
- Docker Compose

## Getting Started

1. **Clone the repository** (if applicable):
   ```bash
   git clone <repository-url>
   cd kafka-docker-project
   ```

2. **Build and start the services**:
   Run the following command to start Zookeeper, Kafka, and Kafka UI:
   ```bash
   docker-compose up -d
   ```

3. **Access Kafka UI**:
   Once the services are up and running, you can access the Kafka UI at:
   ```
   http://localhost:9000
   ```

## Stopping the Services

To stop the running services, use:
```bash
docker-compose down
```

## Configuration

The `docker-compose.yml` file defines the following services:

- **Zookeeper**: Required for Kafka to manage its brokers.
- **Kafka**: The message broker itself, available on:
  - `localhost:9093` for external applications (like Django apps)
  - `kafka:9092` for internal Docker services
- **Kafka UI**: A user interface for managing Kafka topics and monitoring messages.

## Connecting to Kafka

- **From external applications** (Django, etc.): Use `localhost:9093`
- **From Docker containers**: Use `kafka:9092`

## Notes

- Ensure that Docker is running before executing the commands.
- You can customize the configuration in the `docker-compose.yml` file as needed.