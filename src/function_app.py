import azure.functions as func
import logging
import os
import requests
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()

@app.route(route="scalr_trigger", auth_level=func.AuthLevel.ANONYMOUS)
def scalr_trigger(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('Triggering Scalr OIDC Exchange...')

    scalr_hostname = os.environ["SCALR_HOSTNAME"]
    target_audience = os.environ["SCALR_AUDIENCE"]
    service_account_email = os.environ["SCALR_SERVICE_ACCOUNT_EMAIL"]

    try:
        credential = DefaultAzureCredential()

        oidc_token = credential.get_token(f"{target_audience}/.default").token
        logging.info("Acquired OIDC token.")

        exchange_url = f"https://{scalr_hostname}/api/iacp/v3/service-accounts/assume"
        payload = {
            "id_token": oidc_token,
            "service_account_email": service_account_email
        }

        resp = requests.post(exchange_url, json=payload)

        if resp.status_code != 200:
            return func.HttpResponse(f"Scalr Exchange Failed: {resp.text}", status_code=401)

        scalr_token = resp.json().get("access-token")

        return func.HttpResponse(
            f"Success! Access token: '{scalr_token}'.",
            status_code=200
        )

    except Exception as e:
        logging.error(f"Error: {str(e)}")
        return func.HttpResponse(f"Internal Error: {str(e)}", status_code=500)
