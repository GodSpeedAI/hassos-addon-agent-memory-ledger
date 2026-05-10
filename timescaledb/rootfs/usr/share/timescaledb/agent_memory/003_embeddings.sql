-- ==============================================================================
-- Agent Memory Schema: RuVector-backed Embedding Storage
-- Linked to memory items with configurable dimensions and ruhnsw index
-- ==============================================================================
-- Idempotent: safe to run multiple times
-- NOTE: Requires the 'ruvector' extension to be installed

BEGIN;

CREATE SCHEMA IF NOT EXISTS embeddings;

-- Embedding storage is created by 004_setup_agent_memory.sh so the ruvector
-- dimension can honor the agent_memory.embedding_dimension option.

COMMIT;
