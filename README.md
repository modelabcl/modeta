# Modeta

An Elixir/Phoenix OData v4 server that provides Excel connectivity to DuckDB data sources. Modeta enables users to query data from Excel using pivot tables without impacting database performance through intelligent caching.

## Features

- **OData v4 Compliance**: Full compatibility with Excel/Power Query
- **DuckDB Integration**: Direct connection to DuckDB with ADBC
- **Dynamic Schema**: Automatic schema introspection and OData metadata generation
- **Excel Compatible**: Tested and working with Microsoft Excel
- **High Performance**: READ_ONLY connections for maximum concurrency
- **BigQuery Ready**: Architecture supports future BigQuery integration

## Quick Start

### Prerequisites

- Elixir 1.17+
- DuckDB
- ADBC drivers

### Installation

1. Clone the repository and install dependencies:
```bash
mix setup
```

2. Configure your collections in `config/collections.yml`:
```yaml
collections:
  - name: customers
    query: "SELECT * FROM customers"
```

3. Load sample data (optional):
```bash
mix run -e "Modeta.DataLoader.load_customers_csv()"
```

4. Start the server:
```bash
mix phx.server
```

The OData service will be available at `http://localhost:4000/modeta/`

## Excel Connection

1. Open Excel
2. Go to **Data > Get Data > From Other Sources > From OData Feed**
3. Enter the URL: `http://localhost:4000/modeta/`
4. Select your authentication method (Anonymous for local development)
5. Choose the tables/collections you want to import
6. Load the data into Excel

## API Endpoints

- **Service Document**: `GET /modeta/` - Lists available collections
- **Metadata**: `GET /modeta/$metadata` - OData schema definition (XML)
- **Collections**: `GET /modeta/{collection}` - Entity data with OData context

### Example Requests

```bash
# Service document
curl http://localhost:4000/modeta/

# Metadata
curl http://localhost:4000/modeta/\$metadata

# Customer data
curl http://localhost:4000/modeta/customers
```

## Configuration

### Collections

Define your data collections in `config/collections.yml`:

```yaml
collections:
  - name: products
    query: "SELECT id, name, price, category FROM products"
  - name: orders
    query: "SELECT * FROM orders WHERE created_at > '2023-01-01'"
```

## Architecture

```
Excel → OData v4 Server (Elixir) → DuckDB → [Future: BigQuery]
```

### Key Components

- **Phoenix Router**: OData endpoint routing (`/modeta/*`)
- **OData Controller**: Service document, metadata, and collection handlers
- **Cache Module**: DuckDB query execution with ADBC
- **Collections Module**: Configuration and query management
- **Schema Introspection**: Dynamic DuckDB table schema detection

## OData Compliance

Modeta implements OData v4 specification features required for Excel compatibility:

- **Service Document**: JSON format with EntitySet listings
- **Metadata Document**: XML CSDL with dynamic schema
- **Generic Entity Types**: `OpenType="true"` for flexible schemas
- **Content Negotiation**: Supports `odata.metadata=minimal|full|none`
- **Proper Headers**: `OData-Version: 4.0` with enhanced content-types

## Development

### Running Tests

```bash
mix test
```

### Adding New Collections

1. Add configuration to `config/collections.yml`
2. Ensure the underlying data/tables exist in DuckDB
3. Restart the server
4. The collection will be automatically available via OData

## Roadmap

- [ ] BigQuery integration (Phase 2)
- [ ] Intelligent caching with TTL (Phase 3)
- [ ] OData query options (`$filter`, `$orderby`, `$top`, `$skip`)
- [ ] Authentication and authorization
- [ ] Monitoring and metrics dashboard
