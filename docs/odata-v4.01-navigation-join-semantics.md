# OData v4.01 Navigation Property and JOIN Semantics

## Overview

This document explains the **correct OData v4.01 specification** for JOIN semantics based on **query operation type**, not schema configuration.

## Key Principle: Query-Context Determines JOIN Type

**JOIN type should be determined by the OData operation being performed, not hardcoded in schema configuration.**

## OData v4.01 Specification Compliance

### 1. **$expand Operations → Always LEFT JOIN**

**Purpose**: Inclusive semantics - return all primary entities regardless of navigation property existence.

**OData Requirement**: `$expand` must not filter out entities due to missing related data.

**Example**: 
```http
GET /sales/purchases?$expand=Customers
```

**Behavior**: Returns all purchases, including those without customers (customer data will be null).

**SQL**: 
```sql
SELECT main.*, customers.*
FROM (SELECT * FROM purchases) AS main
LEFT JOIN customers ON main.customer_id = customers.id
```

### 2. **Navigation by Key → Always INNER JOIN**

**Purpose**: Entity must exist - return 404 if related entity doesn't exist.

**OData Requirement**: Navigation operations must fail if target entity doesn't exist.

**Example**: 
```http
GET /sales/purchases(1)/Customers
```

**Behavior**: Returns 404 if customer for purchase 1 doesn't exist.

**SQL**: 
```sql
SELECT target.*
FROM customers target
INNER JOIN purchases source ON target.id = source.customer_id
WHERE source.id = 1
```

## Implementation Architecture

### Query-Context Based JOIN Determination

```elixir
def determine_join_type(operation_type) do
  case operation_type do
    :expand -> :left_join           # $expand: inclusive
    :navigation_by_key -> :inner_join   # navigation: must exist
    _ -> :left_join                 # default: OData compliance
  end
end
```

### No Schema Configuration Required

Collections schema should **only** describe relationships, not dictate query execution:

```yaml
collections:
  purchases:
    table: purchases
    references:
      - col: customer_id
        ref: customers(id)    # Relationship definition only
```

## Why Schema-Based JOIN Configuration is Wrong

### 1. **Violates OData Specification**
- OData v4.01 defines JOIN behavior based on operation type
- Schema should describe data structure, not query semantics

### 2. **Context-Dependent Requirements**
- Same relationship needs different JOIN types for different operations
- `purchases → customers` needs LEFT JOIN for $expand, INNER JOIN for navigation

### 3. **Query Optimization Should Be Transparent**
- Client should not need to configure JOIN types
- OData server should handle optimization based on operation semantics

## Current Implementation

### QueryBuilder (Expand Operations)
```elixir
# OData v4.01 specification: $expand always uses LEFT JOIN
# This ensures all primary entities are returned even if navigation property is null
join_sql = "LEFT JOIN"
```

### NavigationResolver (Navigation by Key)
```elixir
# OData v4.01: Navigation by key uses INNER JOIN - related entity must exist
query = """
SELECT target.*
FROM #{qualified_ref_table} target
INNER JOIN #{collection_config.table_name} source ON target.#{ref_column} = source.#{foreign_key_column}
WHERE source.id = #{key}
"""
```

## Benefits of Correct Implementation

### 1. **OData v4.01 Compliance**
- Follows official specification exactly
- Consistent behavior with other OData implementations

### 2. **Automatic Optimization**
- No configuration needed - server chooses optimal JOIN type
- Performance benefits without manual tuning

### 3. **Simplified Configuration**
- Schema describes relationships only
- Eliminates complex JOIN type decisions

### 4. **Predictable Behavior**
- Same operation always uses same JOIN type
- Client expectations align with OData standard

## Official OData Specification Sources

- **OData v4.01 Protocol**: https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part1-protocol.html
- **OData v4.01 CSDL XML**: https://docs.oasis-open.org/odata/odata-csdl-xml/v4.01/odata-csdl-xml-v4.01.html
- **OData v4.01 URL Conventions**: https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part2-url-conventions.html