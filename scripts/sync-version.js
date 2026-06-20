import fs from 'fs';

const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const version = pkg.version;

const tauriPath = 'src-tauri/tauri.conf.json';
const tauriConf = JSON.parse(fs.readFileSync(tauriPath, 'utf8'));
tauriConf.version = version;
fs.writeFileSync(tauriPath, JSON.stringify(tauriConf, null, 2) + '\n');

const cargoPath = 'src-tauri/Cargo.toml';
let cargoToml = fs.readFileSync(cargoPath, 'utf8');
cargoToml = cargoToml.replace(/^version\s*=\s*".*?"/m, `version = "${version}"`);
fs.writeFileSync(cargoPath, cargoToml);

console.log(`Synced version ${version} to tauri.conf.json and Cargo.toml`);
