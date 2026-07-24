#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import Ajv2020 from "ajv/dist/2020.js";
import YAML from "yaml";

const [, , schemaPath, dataPath] = process.argv;

if (!schemaPath || !dataPath) {
  process.stderr.write("Usage: validate-schema.mjs SCHEMA DATA\n");
  process.exit(2);
}

function displayPath(error) {
  const segments = error.instancePath
    .split("/")
    .slice(1)
    .map((segment) => segment.replaceAll("~1", "/").replaceAll("~0", "~"));

  if (error.keyword === "required") {
    segments.push(error.params.missingProperty);
  }

  return segments.reduce((result, segment) => {
    if (/^[A-Za-z_][A-Za-z0-9_-]*$/.test(segment)) {
      return `${result}.${segment}`;
    }
    if (/^[0-9]+$/.test(segment)) {
      return `${result}[${segment}]`;
    }
    return `${result}[${JSON.stringify(segment)}]`;
  }, "$");
}

try {
  const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  const source = fs.readFileSync(dataPath, "utf8");
  const extension = path.extname(dataPath).toLowerCase();
  const data = extension === ".yaml" || extension === ".yml" ? YAML.parse(source) : JSON.parse(source);
  const ajv = new Ajv2020({ allErrors: true, strict: true });
  const validate = ajv.compile(schema);
  const ok = validate(data);
  const errors = (validate.errors ?? []).map((error) => ({
    path: displayPath(error),
    keyword: error.keyword,
    message: error.message,
    schemaPath: error.schemaPath,
  }));

  process.stdout.write(`${JSON.stringify({ ok, errors })}\n`);
  process.exit(ok ? 0 : 1);
} catch (error) {
  process.stdout.write(`${JSON.stringify({
    ok: false,
    errors: [{
      path: "$",
      keyword: "validator",
      message: error instanceof Error ? error.message : String(error),
      schemaPath: "",
    }],
  })}\n`);
  process.exit(1);
}
