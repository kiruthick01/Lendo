import hre from "hardhat";
import { formatEther, createWalletClient, createPublicClient, http, getContract } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync, writeFileSync, existsSync } from "fs";
import { config } from "dotenv";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

// Load .env file from blockchain directory (parent of scripts directory)
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
config({ path: resolve(__dirname, "..", ".env") });

/**
 * Deployment script for CreditCoin Lending Circle Protocol
 * 
 * Deployment order:
 * 1. CreditRegistry
 * 2. ReservePool
 * 3. LendingCircleFactory
 * 
 * Usage:
 *   npx hardhat run scripts/deploy.js --network hardhat
 *   npx hardhat run scripts/deploy.js --network sepolia
 *   npx hardhat run scripts/deploy.js --network creditcoinTestnet
 */

async function main() {
  console.log("🚀 Starting deployment of CreditCoin Lending Circle Protocol...\n");

  // Get network config
  const networkConfig = hre.config.networks[hre.network.name];
  const chainId = networkConfig?.chainId || 102031; // Default to CreditCoin Testnet
  const rpcUrl = networkConfig?.url || "https://rpc.cc3-testnet.creditcoin.network";
  
  const chain = {
    id: chainId,
    name: hre.network.name,
    nativeCurrency: { name: "CreditCoin", symbol: "tCTC", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  };
  
  // Get private key from environment variable (loaded from .env via dotenv)
  let privateKey = process.env.CREDITCOIN_PRIVATE_KEY;
  
  // If not in env, try to get from network config (configVariable)
  if (!privateKey) {
    try {
      const configVar = networkConfig?.accounts?.[0];
      if (configVar && typeof configVar === 'function') {
        privateKey = configVar();
      } else if (configVar) {
        privateKey = typeof configVar === 'string' ? configVar : configVar?.privateKey;
      }
    } catch (e) {
      // Ignore
    }
  }
  
  if (!privateKey) {
    console.error("\n❌ Error: Private key not found!");
    console.error("Make sure .env file exists in blockchain/ directory with:");
    console.error("CREDITCOIN_PRIVATE_KEY=your_private_key_here\n");
    throw new Error("CREDITCOIN_PRIVATE_KEY not found in .env file or environment");
  }
  
  // Ensure private key starts with 0x
  if (!privateKey.startsWith('0x')) {
    privateKey = '0x' + privateKey;
  }
  
  console.log("🔑 Private key loaded from .env file");
  const account = privateKeyToAccount(privateKey);
  
  const walletClient = createWalletClient({
    account,
    chain,
    transport: http(rpcUrl),
  });
  const publicClient = createPublicClient({
    chain,
    transport: http(rpcUrl),
  });
  
  console.log("📝 Deploying with account:", account.address);
  const balance = await publicClient.getBalance({ address: account.address });
  console.log("💰 Account balance:", formatEther(balance), "tCTC\n");

  // ============================================
  // 1. Deploy CreditRegistry
  // ============================================
  console.log("1️⃣  Deploying CreditRegistry...");
  const creditRegistryArtifact = await hre.artifacts.readArtifact("CreditRegistry");
  const creditRegistryHash = await walletClient.deployContract({
    abi: creditRegistryArtifact.abi,
    bytecode: creditRegistryArtifact.bytecode,
    args: [],
  });
  const creditRegistryReceipt = await publicClient.waitForTransactionReceipt({ hash: creditRegistryHash });
  const creditRegistryAddress = creditRegistryReceipt.contractAddress;
  console.log("✅ CreditRegistry deployed to:", creditRegistryAddress);
  
  // Verify base credit score
  const creditRegistry = getContract({
    address: creditRegistryAddress,
    abi: creditRegistryArtifact.abi,
    client: { public: publicClient, wallet: walletClient },
  });
  const baseScore = await creditRegistry.read.BASE_CREDIT_SCORE();
  console.log("   Base credit score:", baseScore.toString(), "\n");

  // ============================================
  // 2. Deploy ReservePool
  // ============================================
  console.log("2️⃣  Deploying ReservePool...");
  const reservePoolArtifact = await hre.artifacts.readArtifact("ReservePool");
  const reservePoolHash = await walletClient.deployContract({
    abi: reservePoolArtifact.abi,
    bytecode: reservePoolArtifact.bytecode,
    args: [],
  });
  const reservePoolReceipt = await publicClient.waitForTransactionReceipt({ hash: reservePoolHash });
  const reservePoolAddress = reservePoolReceipt.contractAddress;
  console.log("✅ ReservePool deployed to:", reservePoolAddress);
  console.log("   Note: Factory will verify circles when created\n");

  // ============================================
  // 3. Deploy LendingCircleFactory
  // ============================================
  console.log("3️⃣  Deploying LendingCircleFactory...");
  const factoryArtifact = await hre.artifacts.readArtifact("LendingCircleFactory");
  const factoryHash = await walletClient.deployContract({
    abi: factoryArtifact.abi,
    bytecode: factoryArtifact.bytecode,
    args: [creditRegistryAddress, reservePoolAddress],
  });
  const factoryReceipt = await publicClient.waitForTransactionReceipt({ hash: factoryHash });
  const factoryAddress = factoryReceipt.contractAddress;
  console.log("✅ LendingCircleFactory deployed to:", factoryAddress);

  // ============================================
  // 4. Update ReservePool factory address
  // ============================================
  console.log("4️⃣  Updating ReservePool factory address...");
  const reservePool = getContract({
    address: reservePoolAddress,
    abi: reservePoolArtifact.abi,
    client: { public: publicClient, wallet: walletClient },
  });
  await reservePool.write.setFactory([factoryAddress]);
  console.log("✅ ReservePool factory address updated\n");

  // ============================================
  // 4.5. Update CreditRegistry factory address
  // ============================================
  console.log("4️⃣.5️⃣  Updating CreditRegistry factory address...");
  await creditRegistry.write.setFactory([factoryAddress]);
  console.log("✅ CreditRegistry factory address updated\n");

  // ============================================
  // 5. Verification and Summary
  // ============================================
  console.log("=".repeat(60));
  console.log("📋 DEPLOYMENT SUMMARY");
  console.log("=".repeat(60));
  console.log("CreditRegistry:", creditRegistryAddress);
  console.log("ReservePool:   ", reservePoolAddress);
  console.log("Factory:       ", factoryAddress);
  console.log("=".repeat(60), "\n");

  // ============================================
  // 6. Save addresses to file (optional)
  // ============================================
  const addresses = {
    network: hre.network.name,
    deployer: account.address,
    creditRegistry: creditRegistryAddress,
    reservePool: reservePoolAddress,
    factory: factoryAddress,
    timestamp: new Date().toISOString(),
  };

  const addressesPath = "./deployments.json";
  let allDeployments = {};
  
  if (existsSync(addressesPath)) {
    allDeployments = JSON.parse(readFileSync(addressesPath, "utf8"));
  }
  
  allDeployments[hre.network.name] = addresses;
  writeFileSync(addressesPath, JSON.stringify(allDeployments, null, 2));
  console.log("💾 Deployment addresses saved to:", addressesPath);
  
  // Also update config.json with deployed addresses
  const configPath = "./config.json";
  if (existsSync(configPath)) {
    const config = JSON.parse(readFileSync(configPath, "utf8"));
    config.contracts = {
      creditRegistry: creditRegistryAddress,
      reservePool: reservePoolAddress,
      factory: factoryAddress,
    };
    writeFileSync(configPath, JSON.stringify(config, null, 2));
    console.log("💾 Config updated:", configPath, "\n");
  } else {
    console.log("");
  }

  console.log("🎉 Deployment completed successfully!");
  console.log("\n📖 Next steps:");
  console.log("   1. Update frontend/lib/contracts/config.ts with the deployed addresses");
  console.log("   2. Use factory.createCircle() to create a new lending circle");
  console.log("   3. Participants can requestToJoin() and get approved");
  console.log("   4. Start making monthly contributions");
  console.log("   5. Vote and execute payouts");
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:");
    console.error(error);
    process.exit(1);
  });
