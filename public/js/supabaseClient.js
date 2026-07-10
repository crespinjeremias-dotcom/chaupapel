import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

const SUPABASE_URL = 'https://mptcnzpgztbiespxpbnp.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1wdGNuenBnenRiaWVzcHhwYm5wIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM2NDA2OTEsImV4cCI6MjA5OTIxNjY5MX0.2dcfZTgvwy9Fb-amRlyyNBO-uGaUc7DFh4CW-S9ORx4';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
