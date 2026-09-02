#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execute = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const options = Object.fromEntries(process.argv.slice(2).map(argument => {
  const index = argument.indexOf("=");
  if (!argument.startsWith("--") || index < 3) throw new Error(`Expected --name=value, received ${argument}`);
  return [argument.slice(2, index), argument.slice(index + 1)];
}));
for (const name of ["autonomous-database-id", "table-name"]) if (!options[name]) throw new Error(`Missing --${name}`);

const databaseId = options["autonomous-database-id"];
const tableName = options["table-name"];
const profile = options.profile || "DEFAULT";
const region = options.region || "us-ashburn-1";
const readCapacity = Number(options["read-capacity-units"] || 500);
const writeCapacity = Number(options["write-capacity-units"] || 500);
const lifetimeMinutes = Number(options["access-key-lifetime-minutes"] || 720);
const apply = options.apply === "true";
const benchmarkRepository = path.resolve(options["benchmark-repository"] || path.join(here, "..", "..", "kvs-benchmark"));
if (![readCapacity, writeCapacity, lifetimeMinutes].every(Number.isInteger) || readCapacity < 1 || writeCapacity < 1 || lifetimeMinutes < 1) throw new Error("Capacity and lifetime values must be positive integers");

async function command(file, args, environment = process.env) {
  const { stdout } = await execute(file, args, { env: environment, windowsHide: true, maxBuffer: 8 * 1024 * 1024 });
  return stdout;
}
async function json(file, args, environment) { return JSON.parse(await command(file, args, environment)); }
const adb = (await json("oci", ["db", "autonomous-database", "get", "--autonomous-database-id", databaseId, "--profile", profile, "--region", region, "--output", "json"])).data;
if (adb["lifecycle-state"] !== "AVAILABLE") throw new Error(`ADB must be AVAILABLE; found ${adb["lifecycle-state"]}`);
if (adb["license-model"] !== "BRING_YOUR_OWN_LICENSE") throw new Error("ADB is not BYOL");
if (adb["compute-model"] !== "ECPU" || Number(adb["compute-count"]) !== 2) throw new Error("ADB must use exactly 2 ECPU");
if (adb["is-auto-scaling-enabled"]) throw new Error("ADB base compute autoscaling must be disabled");
if (!apply) {
  console.log("ADB validation passed: AVAILABLE, BYOL, 2 ECPU, base autoscaling disabled. No resource was changed.");
  process.exit(0);
}

const alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const random = crypto.randomBytes(20);
const adminPassword = `Kvs1aA${[...random].map(value => alphabet[value % alphabet.length]).join("")}`;
console.log("Rotating the transient ADMIN password for DynamoDB API bootstrap...");
await command("oci", ["db", "autonomous-database", "update", "--autonomous-database-id", databaseId, "--profile", profile, "--region", region, "--admin-password", adminPassword, "--force", "--wait-for-state", "AVAILABLE", "--max-wait-seconds", "1200", "--wait-interval-seconds", "15", "--output", "json"]);

const endpoint = `https://dataaccess.adb.${region}.oraclecloudapps.com/adb/keyvaluestore/v1/${databaseId}`;
const authEndpoint = `https://dataaccess.adb.${region}.oraclecloudapps.com/adb/auth/v1/databases/${databaseId}/accesskeys`;
const request = { name: `kvs-benchmark-${new Date().toISOString().replace(/\D/g, "").slice(0, 14)}`, description: "Temporary credential for a KVS benchmark", permissions: [{ actions: ["ADMIN_ANY"] }], expiration_minutes: lifetimeMinutes };
let accessKey;
const deadline = Date.now() + 12 * 60_000;
while (!accessKey) {
  const response = await fetch(authEndpoint, { method: "POST", headers: { Authorization: `Basic ${Buffer.from(`ADMIN:${adminPassword}`).toString("base64")}`, "Content-Type": "application/json", "Request-Id": crypto.randomUUID().replaceAll("-", "") }, body: JSON.stringify(request) });
  if (response.ok) accessKey = await response.json();
  else {
    if (Date.now() >= deadline) throw new Error(`DynamoDB API access-key bootstrap failed (${response.status}): ${(await response.text()).slice(0, 500)}`);
    console.log("DynamoDB API is not ready yet; retrying in 20 seconds...");
    await new Promise(resolve => setTimeout(resolve, 20_000));
  }
}
if (!accessKey.access_key_id || !accessKey.secret_access_key) throw new Error("Access-key bootstrap returned an incomplete response");

const awsEnvironment = { ...process.env, AWS_ACCESS_KEY_ID: accessKey.access_key_id, AWS_SECRET_ACCESS_KEY: accessKey.secret_access_key, AWS_DEFAULT_REGION: region };
const common = ["--table-name", tableName, "--endpoint-url", endpoint, "--region", region, "--output", "json"];
let tableExists = true;
try { await command("aws", ["dynamodb", "describe-table", ...common], awsEnvironment); } catch { tableExists = false; }
if (tableExists) {
  console.log(`Updating existing table '${tableName}' to ${readCapacity} RCU / ${writeCapacity} WCU...`);
  await command("aws", ["dynamodb", "update-table", ...common, "--provisioned-throughput", `ReadCapacityUnits=${readCapacity},WriteCapacityUnits=${writeCapacity}`], awsEnvironment);
} else {
  console.log(`Creating table '${tableName}' at ${readCapacity} RCU / ${writeCapacity} WCU...`);
  await command("aws", ["dynamodb", "create-table", ...common, "--attribute-definitions", "AttributeName=pk,AttributeType=S", "AttributeName=sk,AttributeType=S", "--key-schema", "AttributeName=pk,KeyType=HASH", "AttributeName=sk,KeyType=RANGE", "--provisioned-throughput", `ReadCapacityUnits=${readCapacity},WriteCapacityUnits=${writeCapacity}`], awsEnvironment);
}
await command("aws", ["dynamodb", "wait", "table-exists", "--table-name", tableName, "--endpoint-url", endpoint, "--region", region], awsEnvironment);
const description = await json("aws", ["dynamodb", "describe-table", ...common], awsEnvironment);

const secretDirectory = path.join(benchmarkRepository, ".secrets", "adb-runtime");
const runtimePath = path.join(secretDirectory, "adb-api.runtime.json");
fs.mkdirSync(secretDirectory, { recursive: true, mode: 0o700 });
fs.writeFileSync(runtimePath, `${JSON.stringify({ databaseId, region, endpoint, accessKeyId: accessKey.access_key_id, secretAccessKey: accessKey.secret_access_key, expirationTime: accessKey.expiration_time || accessKey.expiration_timestamp, tableNames: [tableName] }, null, 2)}\n`, { mode: 0o600 });
if (process.platform === "win32") {
  const identity = (await command("whoami", [])).trim();
  await command("icacls", [secretDirectory, "/inheritance:r", "/grant:r", `${identity}:(OI)(CI)F`, "/T", "/Q"]);
  await command("icacls", [runtimePath, "/inheritance:r", "/grant:r", `${identity}:F`, "/Q"]);
} else {
  fs.chmodSync(secretDirectory, 0o700); fs.chmodSync(runtimePath, 0o600);
}
console.log(`ADB_READY database=${adb["display-name"]} license=${adb["license-model"]} table=${tableName} tableState=${description.Table.TableStatus} rcu=${description.Table.ProvisionedThroughput.ReadCapacityUnits} wcu=${description.Table.ProvisionedThroughput.WriteCapacityUnits} runtime=${runtimePath}`);
