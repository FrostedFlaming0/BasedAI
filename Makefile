.PHONY: install test test-contracts test-miner test-validator clean deploy-testnet deploy-mainnet lint

install:
	cd contracts && forge install
	cd miner && pip install -e .
	cd validator && pip install -e .
	cd client/typescript && npm install
	cd client/python && pip install -e .

test: test-contracts test-miner test-validator

test-contracts:
	cd contracts && forge test -vvv

test-miner:
	cd miner && pytest

test-validator:
	cd validator && pytest

lint:
	cd contracts && forge fmt --check
	cd miner && ruff check src tests
	cd validator && ruff check src tests
	cd client/typescript && npm run lint

deploy-testnet:
	cd contracts && forge script script/Deploy.s.sol --rpc-url $(INK_SEPOLIA_RPC) --broadcast --verify

deploy-mainnet:
	@echo "Refusing to deploy to mainnet without explicit confirmation."
	@echo "Run: cd contracts && forge script script/Deploy.s.sol --rpc-url $$INK_RPC --broadcast --verify"

clean:
	cd contracts && forge clean
	rm -rf miner/.pytest_cache validator/.pytest_cache
	rm -rf client/typescript/node_modules client/typescript/dist
