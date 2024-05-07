# TORC Token

This repository contains the implementation and deployment scripts for the TORC token. The TORC token is a standard ERC20 token intended for use in various decentralized finance (DeFi) applications.

## Prerequisites

Before you begin, ensure you have the following installed on your system:
- Node.js and npm (Node Package Manager)
- Python 3 (for running the frontend server)
- Hardhat (for running blockchain tasks)

## Installation

To set up the project environment, follow these steps:

1. Clone the repository to your local machine:
   ```bash
   git clone https://github.com/taproots-wisdom/torc.git
   cd torctoken
   ```

2. Install the necessary npm packages:
   ```bash
   npm install
   ```

## Running Modules

To deploy the TORC token modules on a testnet, use the following command:

```bash
$ npx hardhat ignition deploy ignition/modules/TORCTestnetModule.ts
```

This command deploys the TORC token to a testnet environment specified in your Hardhat configuration. Ensure your Hardhat environment is correctly set up with your testnet details and private keys.

## Testing

To run the tests defined for the TORC token, execute the following command:

```bash
npx hardhat test
```

This command runs the test suite defined in the Hardhat project, which tests various functionalities of the TORC token.

## Running the Frontend Server

To serve the frontend application locally, navigate to the directory containing your `index.html` file and run:

```bash
python3 -m http.server
```

This command starts a simple HTTP server on the default port (usually 8000). You can access the frontend by navigating to `http://localhost:8000/frontend/index.html` in your web browser.

## Additional Information

For more details about the TORC token and its functionalities, refer to the official documentation or the `docs` folder in this repository.

---

For any issues or contributions, please open an issue or submit a pull request to the repository.
