# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Elixir/Phoenix project implementing an OData server that uses DuckDB as a cache/proxy layer to connect Excel with BigQuery. The architecture enables multiple users to query data from Excel using pivot tables without impacting BigQuery performance or costs.

## Architecture

### Data Flow
```
Excel → OData Server (Elixir) → DuckDB → BigQuery
```

### Technology Stack
- **Backend**: Elixir/Phoenix
- **Database**: DuckDB with BigQuery extension
- **Connectivity**: ADBC for DuckDB connections
- **Protocol**: OData v4 (JSON for data, XML/CSDL for metadata)
- **Client**: Excel/Power Query

## Development Phases

The project is designed for 3-phase implementation:

1. **Phase 1**: DuckDB standalone with local data
2. **Phase 2**: BigQuery integration via DuckDB extension
3. **Phase 3**: Intelligent caching with lifecycle management

## Key Architectural Patterns

### Concurrency Model
- Direct DuckDB connections per Cowboy worker process (not pooled)
- DuckDB handles internal concurrency in READ_ONLY mode
- GenServers only for table lifecycle management (refresh, sync, monitoring)
- ADBC connections made directly from requests

### Table Lifecycle Management
- Each table has a dedicated GenServer for lifecycle operations
- Separate concerns: GenServers handle sync/refresh, direct connections handle queries
- Registry-based table lookup
- Dynamic supervisor for table GenServers

### OData Implementation
- Required XML/CSDL metadata endpoint at `/$metadata`
- JSON responses for data queries
- Server-side paging with `@odata.nextLink`
- Type mapping from DuckDB to OData EDM types

## Configuration by Environment

### Development (Phase 1)
```elixir
config :my_app,
  duckdb_mode: :local_only,
  data_path: "data/"
```

### Staging (Phase 2)
```elixir 
config :my_app,
  duckdb_mode: :proxy,
  gcp_project_id: "staging-project"
```

### Production (Phase 3)
```elixir
config :my_app,
  duckdb_mode: :cache,
  gcp_project_id: "prod-project",
  bigquery_tables: %{
 "productos" => %{
   dataset: "warehouse",
   table: "dim_productos",
   ttl: 86400,
   refresh_interval: 3600
 }
  }
```

## Core Routes
```elixir
scope "/modeta" do
  get "/$metadata", ODataController, :metadata   # XML metadata (required)
  get "/", ODataController, :service_document    # OData service document
  get "/:collection", ODataController, :collection  # JSON data queries
end
```

## Key Implementation Considerations

- Use READ_ONLY mode for DuckDB connections for maximum concurrency
- Implement server-side filtering by translating OData `$filter` to SQL WHERE clauses
- Handle large tables with server-side paging and `@odata.nextLink`
- Map DuckDB types to OData EDM types in metadata generation
- Structure logging with table name, duration, rows returned, and cache status

## OData Implementation Details

The OData v4 server implementation includes:

### Excel/Power Query Compatibility
- Generic `EntityType Name="Object" OpenType="true"` for dynamic schemas
- Proper OData headers: `OData-Version: 4.0`
- Enhanced content-type: `application/json;odata.metadata=minimal;odata.streaming=true;IEEE754Compatible=false`
- Absolute URLs in `@odata.context` fields
- JSON field ordering: `@odata.context` first, then `value`

### Endpoints
- **Service Document**: `/modeta/` - Lists available collections
- **Metadata**: `/modeta/$metadata` - XML schema definition (CSDL)
- **Collections**: `/modeta/{collection}` - Entity data with OData context

### Content Negotiation
- Supports `odata.metadata=minimal|full|none` in Accept headers
- Returns appropriate content-type with OData parameters
- XML metadata always uses compact single-line format

### Schema Introspection
- Dynamically queries DuckDB table schemas using `DESCRIBE`
- Creates temporary views for complex queries
- Maps DuckDB types to OData EDM types
- Uses generic Object entity type for maximum compatibility

## Monitoring Metrics
- Query latency per table
- Cache hit rates
- Active DuckDB connections
- BigQuery sync errors
- Memory usage per table