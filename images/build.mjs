#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const imageDirectory = path.dirname(fileURLToPath(import.meta.url));
const options = Object.fromEntries(process.argv.slice(2).map(value => {
  const index = value.indexOf("=");
  if (!value.startsWith("--") || index < 3) throw new Error(`Expected --name=value, received ${value}`);
  return [value.slice(2, index), value.slice(index + 1)];
}));
const provider = options.provider || "all";
if (!["aws", "oci", "all"].includes(provider)) throw new Error("--provider must be aws, oci, or all");
const validateOnly = options["validate-only"] === "true";
const packer = process.env.PACKER_BIN || "packer";

function run(args) {
  const result = spawnSync(packer, args, { cwd: imageDirectory, encoding: "utf8", stdio: "inherit", shell: false });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Packer exited ${result.status}: ${args.join(" ")}`);
}

function build(selected) {
  const template = path.join(imageDirectory, `${selected}-runner.pkr.hcl`);
  const configured = options[`${selected}-var-file`] || path.join(imageDirectory, `${selected}.pkrvars.hcl`);
  if (!fs.existsSync(configured)) throw new Error(`Missing ${selected} variable file: copy ${selected}.pkrvars.hcl.example and fill its pinned inputs`);
  run(["init", template]);
  run(["fmt", "-check", template]);
  run(["validate", `-var-file=${configured}`, template]);
  if (!validateOnly) run(["build", `-var-file=${configured}`, template]);
}

for (const selected of provider === "all" ? ["aws", "oci"] : [provider]) build(selected);
console.log(validateOnly ? "IMAGE_TEMPLATES_VALID" : "IMAGE_BUILDS_COMPLETE");

