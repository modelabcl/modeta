# OData v4.01 Navigation Property and JOIN Semantics

## Overview

This document summarizes the OData v4.01 specification regarding navigation properties and their equivalent JOIN semantics for SQL implementations.

## Navigation Property Definitions

Navigation properties in OData CSDL define relationships between entity types. The key attributes that affect JOIN behavior are:

### 1. Nullability (`Nullable` attribute)
- `Nullable="false"` → **INNER JOIN** semantics
- `Nullable="true"` or unspecified → **LEFT OUTER JOIN** semantics

### 2. Multiplicity/Cardinality
- `0..1` (zero or one) → Optional relationship
- `1` (exactly one) → Required relationship  
- `*` (zero or more) → Collection relationship

### 3. Referential Constraints
Define the foreign key relationship between entities:

```xml
<NavigationProperty Name="Category" Type="NS.CategoryType" Nullable="false">
  <ReferentialConstraint Property="CategoryID" ReferencedProperty="ID"/>
</NavigationProperty>
```

## JOIN Semantics Mapping

Based on the OData v4.01 CSDL specification:

### INNER JOIN (Required Relationships)
Use when:
- Navigation property has `Nullable="false"`
- Multiplicity is `1` (exactly one)
- Related entity MUST exist

**Example:** Product → Category (every product must have a category)
```xml
<NavigationProperty Name="Category" Type="NS.CategoryType" Nullable="false">
  <ReferentialConstraint Property="CategoryID" ReferencedProperty="ID"/>
</NavigationProperty>
```

**SQL:** `INNER JOIN categories ON products.category_id = categories.id`

### LEFT OUTER JOIN (Optional Relationships)  
Use when:
- Navigation property has `Nullable="true"` or no explicit nullable attribute
- Multiplicity is `0..1` (zero or one)
- Related entity MAY exist

**Example:** Customer → PreferredStore (customer may not have a preferred store)
```xml
<NavigationProperty Name="PreferredStore" Type="NS.StoreType" Nullable="true">
  <ReferentialConstraint Property="PreferredStoreID" ReferencedProperty="ID"/>
</NavigationProperty>
```

**SQL:** `LEFT JOIN stores ON customers.preferred_store_id = stores.id`

### Collection Relationships (`*` multiplicity)
For one-to-many relationships, the JOIN direction matters:
- Navigation from "one" side → LEFT JOIN (to include entities without related items)
- Navigation from "many" side → INNER JOIN (related entity must exist)

## Implementation Guidelines

### 1. Default Behavior
- **$expand operations should use LEFT OUTER JOIN by default** to match OData's inclusive semantics
- This ensures all primary entities are returned even if related entities don't exist

### 2. Referential Constraint Analysis
Analyze the collection configuration to determine appropriate JOIN type:

```elixir
def determine_join_type(reference_config) do
  case reference_config do
    %{"nullable" => false} -> :inner_join
    %{"required" => true} -> :inner_join  
    %{"multiplicity" => "1"} -> :inner_join
    _ -> :left_join  # Default to inclusive behavior
  end
end
```

### 3. Configuration Enhancement
Extend collection configuration to specify JOIN semantics:

```yaml
collections:
  purchases:
    table: purchases
    references:
      - col: customer_id
        ref: customers(id)
        nullable: false      # → INNER JOIN
        multiplicity: "1"    # exactly one customer per purchase
      - col: discount_id  
        ref: discounts(id)
        nullable: true       # → LEFT JOIN
        multiplicity: "0..1" # optional discount
```

## OData Specification Sources

- **OData v4.01 Protocol**: https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part1-protocol.html
- **OData v4.01 CSDL XML**: https://docs.oasis-open.org/odata/odata-csdl-xml/v4.01/odata-csdl-xml-v4.01.html
- **OData v4.01 URL Conventions**: https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part2-url-conventions.html

## Current Implementation Status

The current QueryBuilder implementation uses LEFT JOIN for all navigation properties. This aligns with OData's inclusive semantics but could be enhanced to support INNER JOIN when referential constraints indicate required relationships.

## Recommended Implementation

1. **Keep LEFT JOIN as default** for $expand operations (OData standard behavior)
2. **Add configuration support** for explicit JOIN type specification
3. **Implement INNER JOIN option** for performance optimization when appropriate
4. **Maintain backward compatibility** with existing behavior