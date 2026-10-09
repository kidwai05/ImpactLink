// src/scripts/sql_summary.js
// Simple script to check presence of sql file and print a short summary.
const fs = require('fs');
const path = require('path');

const sqlPath = path.join(__dirname, '..', '..', 'xyz1.sql');

if (!fs.existsSync(sqlPath)) {
  console.error('xyz1.sql not found at', sqlPath);
  process.exit(1);
}

const content = fs.readFileSync(sqlPath, 'utf8');
const lines = content.split(/\r?\n/);

const tableCount = (content.match(/CREATE TABLE/gi) || []).length;
const procCount = (content.match(/CREATE OR REPLACE PROCEDURE/gi) || []).length;
const viewCount = (content.match(/CREATE OR REPLACE VIEW/gi) || []).length;
const triggerCount = (content.match(/CREATE OR REPLACE TRIGGER/gi) || [])?.length || (content.match(/CREATE OR REPLACE TRIGGER/gi) || []).length;

console.log('xyz1.sql summary');
console.log('Path:', sqlPath);
console.log('Total lines:', lines.length);
console.log('CREATE TABLE statements:', tableCount);
console.log('CREATE OR REPLACE PROCEDURE statements:', procCount);
console.log('CREATE OR REPLACE VIEW statements:', viewCount);
console.log('TRIGGER statements:', triggerCount);
console.log('\nFirst 20 lines:\n');
console.log(lines.slice(0, 20).join('\n'));
