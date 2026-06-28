.PHONY: install test test-contracts test-miner test-validator test-gateway clean deploy-testnet deploy-mainnet lint

install:
	cd contracts && forge install
	cd miner && pip install -e .
	cd validator && pip install -e .
	cd gateway && pip install -e .
	cd client/typescript && npm install
	cd client/python && pip install -e .

test: test-contracts test-miner test-validator test-gateway

test-contracts:
	cd contracts && forge test -vvv

test-miner:
	cd miner && pytest

test-validator:
	cd validator && pytest

test-gateway:
	cd gateway && pytest

lint:
	cd contracts && forge fmt --check
	cd miner && ruff check src tests
	cd validator && ruff check src tests
	cd gateway && ruff check src tests
	cd client/typescript && npm run lint

deploy-testnet:
	cd contracts && forge script script/Deploy.s.sol --rpc-url $(INK_SEPOLIA_RPC) --broadcast --verify

deploy-mainnet:
	@echo "Refusing to deploy to mainnet without explicit confirmation."
	@echo "Mainnet hosts the L1 BrainNFT + bridge adapter (DeployMainnet), NOT the L2 stack (Deploy)."
	@echo "Run: cd contracts && forge script script/DeployMainnet.s.sol --rpc-url $$MAINNET_RPC --broadcast --verify"

clean:
	cd contracts && forge clean
	rm -rf miner/.pytest_cache validator/.pytest_cache
	rm -rf client/typescript/node_modules client/typescript/dist
