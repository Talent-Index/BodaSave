import { GenericContractsDeclaration } from "~~/utils/scaffold-eth/contract";

const externalContracts = {
  84532: {
    MockUSDC: {
      address: "0x445D27Fd71d52341484239E39763193A8940753f",
      abi: [
        {
          "inputs": [
            { "internalType": "uint256", "name": "initialSupply", "type": "uint256" },
            { "internalType": "address", "name": "initialOwner", "type": "address" }
          ],
          "stateMutability": "nonpayable",
          "type": "constructor"
        },
        { "inputs": [], "name": "ERC20InvalidApprover", "type": "error" },
        { "inputs": [], "name": "ERC20InvalidReceiver", "type": "error" },
        { "inputs": [], "name": "ERC20InvalidSender", "type": "error" },
        { "inputs": [], "name": "ERC20InvalidSpender", "type": "error" },
        {
          "inputs": [
            { "internalType": "address", "name": "spender", "type": "address" },
            { "internalType": "uint256", "name": "allowance", "type": "uint256" },
            { "internalType": "uint256", "name": "needed", "type": "uint256" }
          ],
          "name": "ERC20InsufficientAllowance",
          "type": "error"
        },
        {
          "inputs": [
            { "internalType": "address", "name": "sender", "type": "address" },
            { "internalType": "uint256", "name": "balance", "type": "uint256" },
            { "internalType": "uint256", "name": "needed", "type": "uint256" }
          ],
          "name": "ERC20InsufficientBalance",
          "type": "error"
        },
        {
          "anonymous": false,
          "inputs": [
            { "indexed": true, "internalType": "address", "name": "owner", "type": "address" },
            { "indexed": true, "internalType": "address", "name": "spender", "type": "address" },
            { "indexed": false, "internalType": "uint256", "name": "value", "type": "uint256" }
          ],
          "name": "Approval",
          "type": "event"
        },
        {
          "anonymous": false,
          "inputs": [
            { "indexed": true, "internalType": "address", "name": "from", "type": "address" },
            { "indexed": true, "internalType": "address", "name": "to", "type": "address" },
            { "indexed": false, "internalType": "uint256", "name": "value", "type": "uint256" }
          ],
          "name": "Transfer",
          "type": "event"
        },
        {
          "inputs": [
            { "internalType": "address", "name": "owner", "type": "address" },
            { "internalType": "address", "name": "spender", "type": "address" }
          ],
          "name": "allowance",
          "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }],
          "stateMutability": "view",
          "type": "function"
        },
        {
          "inputs": [
            { "internalType": "address", "name": "spender", "type": "address" },
            { "internalType": "uint256", "name": "value", "type": "uint256" }
          ],
          "name": "approve",
          "outputs": [{ "internalType": "bool", "name": "", "type": "bool" }],
          "stateMutability": "nonpayable",
          "type": "function"
        },
        {
          "inputs": [{ "internalType": "address", "name": "account", "type": "address" }],
          "name": "balanceOf",
          "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }],
          "stateMutability": "view",
          "type": "function"
        },
        {
          "inputs": [],
          "name": "decimals",
          "outputs": [{ "internalType": "uint8", "name": "", "type": "uint8" }],
          "stateMutability": "view",
          "type": "function"
        },
        {
          "inputs": [
            { "internalType": "address", "name": "spender", "type": "address" },
            { "internalType": "uint256", "name": "subtractedValue", "type": "uint256" }
          ],
          "name": "decreaseAllowance",
          "outputs": [{ "internalType": "bool", "name": "", "type": "bool" }],
          "stateMutability": "nonpayable",
          "type": "function"
        },
        {
          "inputs": [
            { "internalType": "address", "name": "spender", "type": "address" },
            { "internalType": "uint256", "name": "addedValue", "type": "uint256" }
          ],
          "name": "increaseAllowance",
          "outputs": [{ "internalType": "bool", "name": "", "type": "bool" }],
          "stateMutability": "nonpayable",
          "type": "function"
        },
        {
          "inputs": [{ "internalType": "uint256", "name": "amount", "type": "uint256" }],
          "name": "faucet",
          "outputs": [],
          "stateMutability": "nonpayable",
          "type": "function"
        },
        {
          "inputs": [],
          "name": "name",
          "outputs": [{ "internalType": "string", "name": "", "type": "string" }],
          "stateMutability": "view",
          "type": "function"
        },
        {
          "inputs": [],
          "name": "symbol",
          "outputs": [{ "internalType": "string", "name": "", "type": "string" }],
          "stateMutability": "view",
          "type": "function"
        },
        {
          "inputs": [],
          "name": "totalSupply",
          "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }],
          "stateMutability": "view",
          "type": "function"
        },
        {
          "inputs": [
            { "internalType": "address", "name": "to", "type": "address" },
            { "internalType": "uint256", "name": "value", "type": "uint256" }
          ],
          "name": "transfer",
          "outputs": [{ "internalType": "bool", "name": "", "type": "bool" }],
          "stateMutability": "nonpayable",
          "type": "function"
        },
        {
          "inputs": [
            { "internalType": "address", "name": "from", "type": "address" },
            { "internalType": "address", "name": "to", "type": "address" },
            { "internalType": "uint256", "name": "value", "type": "uint256" }
          ],
          "name": "transferFrom",
          "outputs": [{ "internalType": "bool", "name": "", "type": "bool" }],
          "stateMutability": "nonpayable",
          "type": "function"
        }
      ],
    },
    BodaBodaSavings: {
      address: "0xe350d03eDeC4A3f9Be8560ab68672669334b375b",
      abi: [
        {
          "inputs": [
            { "internalType": "address", "name": "_stablecoin", "type": "address" },
            { "internalType": "address", "name": "initialOwner", "type": "address" }
          ],
          "stateMutability": "nonpayable",
          "type": "constructor"
        },
        { "inputs": [{ "internalType": "address", "name": "owner", "type": "address" }], "name": "OwnableInvalidOwner", "type": "error" },
        { "inputs": [{ "internalType": "address", "name": "account", "type": "address" }], "name": "OwnableUnauthorizedAccount", "type": "error" },
        {
          "anonymous": false,
          "inputs": [
            { "indexed": true, "internalType": "address", "name": "rider", "type": "address" },
            { "indexed": false, "internalType": "uint256", "name": "amount", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "savingsPart", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "loanPart", "type": "uint256" }
          ],
          "name": "Deposit",
          "type": "event"
        },
        {
          "anonymous": false,
          "inputs": [
            { "indexed": true, "internalType": "address", "name": "previousOwner", "type": "address" },
            { "indexed": true, "internalType": "address", "name": "newOwner", "type": "address" }
          ],
          "name": "OwnershipTransferred",
          "type": "event"
        },
        {
          "anonymous": false,
          "inputs": [
            { "indexed": true, "internalType": "address", "name": "rider", "type": "address" },
            { "indexed": false, "internalType": "uint256", "name": "amount", "type": "uint256" }
          ],
          "name": "SavingsWithdrawn",
          "type": "event"
        },
        {
          "inputs": [{ "internalType": "uint256", "name": "amount", "type": "uint256" }],
          "name": "deposit",
          "outputs": [],
          "stateMutability": "nonpayable",
          "type": "function"
        },
        {
          "inputs": [{ "internalType": "address", "name": "rider", "type": "address" }],
          "name": "getBalances",
          "outputs": [
            { "internalType": "uint256", "name": "savingsBalance", "type": "uint256" },
            { "internalType": "uint256", "name": "loanPoolBalance", "type": "uint256" }
          ],
          "stateMutability": "view",
          "type": "function"
        },
        {
          "inputs": [],
          "name": "loanPool",
          "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }],
          "stateMutability": "view",
          "type": "function"
        },
        {
          "inputs": [],
          "name": "owner",
          "outputs": [{ "internalType": "address", "name": "", "type": "address" }],
          "stateMutability": "view",
          "type": "function"
        },
        {
          "inputs": [],
          "name": "renounceOwnership",
          "outputs": [],
          "stateMutability": "nonpayable",
          "type": "function"
        },
        {
          "inputs": [],
          "name": "savingsPool",
          "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }],
          "stateMutability": "view",
          "type": "function"
        },
        {
          "inputs": [],
          "name": "stablecoin",
          "outputs": [{ "internalType": "contract IERC20", "name": "", "type": "address" }],
          "stateMutability": "view",
          "type": "function"
        },
        {
          "inputs": [{ "internalType": "address", "name": "newOwner", "type": "address" }],
          "name": "transferOwnership",
          "outputs": [],
          "stateMutability": "nonpayable",
          "type": "function"
        },
        {
          "inputs": [{ "internalType": "uint256", "name": "amount", "type": "uint256" }],
          "name": "withdrawSavings",
          "outputs": [],
          "stateMutability": "nonpayable",
          "type": "function"
        }
      ],
    },
  },
} as const;

export default externalContracts satisfies GenericContractsDeclaration;
