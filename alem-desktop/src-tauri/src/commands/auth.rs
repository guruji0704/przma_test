use tauri::State;
use crate::AppState;
use serde::{Deserialize, Serialize};
use arrow::array::Array;
use arrow_array::StringArray;

// ══════════════════════════════════════════════════════════════════════════
// Response Structs
// ══════════════════════════════════════════════════════════════════════════

#[derive(serde::Serialize)]
pub struct CaptchaResponse {
    pub answer_data: String,
    pub token: String,
    pub r#type: String,
    pub seconds_valid: i64,
}

#[derive(Deserialize)]
struct ApiMessageResponse {
    message: Option<String>,
    error: Option<String>,
    user_id: Option<String>,
    email: Option<String>,
}

#[derive(Serialize)]
pub struct RegisterResponse {
    pub success: bool,
    pub user_id: Option<String>,
    pub email: Option<String>,
    pub message: String,
}

#[derive(Serialize)]
pub struct GenericResponse {
    pub success: bool,
    pub message: String,
}

#[derive(Serialize)]
pub struct LoginResponse {
    pub success: bool,
    pub did: Option<String>,
    pub access_token: Option<String>,
}

async fn get_server_url(db: &crate::db::lancedb::LanceDBManager) -> String {
    db.get_server_url().await.unwrap_or(None).unwrap_or_else(|| "http://172.235.18.126:4201".to_string())
}

// ══════════════════════════════════════════════════════════════════════════
// Commands
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn get_captcha(state: State<'_, AppState>) -> Result<CaptchaResponse, String> {
    let server_url = get_server_url(&state.lancedb).await;

    let resp = reqwest::Client::new()
        .get(format!("{}/api/v1/pleroma/captcha", server_url))
        .send().await
        .map_err(|e| format!("Network error: {}. Please check your internet connection and server URL.", e))?;

    if !resp.status().is_success() {
        return Err(format!("Server error: {}", resp.status()));
    }

    let c: serde_json::Value = resp.json().await
        .map_err(|e| format!("Failed to parse captcha: {}", e))?;

    Ok(CaptchaResponse {
        answer_data:   c["answer_data"].as_str().unwrap_or("").to_string(),
        token:         c["token"].as_str().unwrap_or("").to_string(),
        r#type:        c["type"].as_str().unwrap_or("").to_string(),
        seconds_valid: c["seconds_valid"].as_i64().unwrap_or(0),
    })
}

#[tauri::command]
pub async fn register_account(
    nickname: String,
    email: String,
    password: String,
    captcha_solution: String,
    captcha_token: String,
    state: State<'_, AppState>,
) -> Result<RegisterResponse, String> {
    let server_url = get_server_url(&state.lancedb).await;

    log::info!("Registering: {} @ {}", nickname, server_url);

    let resp = reqwest::Client::new()
        .post(format!("{}/api/v1/account/register", server_url))
        .json(&serde_json::json!({
            "nickname":         nickname,
            "email":            email,
            "password":         password,
            "captcha_solution": captcha_solution,
            "captcha_token":    captcha_token,
        }))
        .send().await
        .map_err(|e| format!("Network error: {}. Please check your internet connection and server URL.", e))?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();

    if !status.is_success() {
        log::error!("Registration failed: {}", body);
        return Err(format!("Registration failed: {}", body));
    }

    // Parse the JSON response
    let result: serde_json::Value = serde_json::from_str(&body)
        .map_err(|e| format!("JSON parse error: {}", e))?;

    log::info!("Registration response: {}", result);

    // Extract user_id and message from the new flow
    let user_id = result["user_id"].as_str().map(|s| s.to_string());
    let resp_email = result["email"].as_str().map(|s| s.to_string());
    let message = result["message"].as_str().unwrap_or("Registration successful. Check your email for the verification code.").to_string();

    Ok(RegisterResponse {
        success: true,
        user_id,
        email: resp_email,
        message,
    })
}

#[tauri::command]
pub async fn verify_email(
    user_id: String,
    code: String,
    state: State<'_, AppState>,
) -> Result<GenericResponse, String> {
    let server_url = get_server_url(&state.lancedb).await;

    let resp = reqwest::Client::new()
        .post(format!("{}/api/v1/account/verify_email", server_url))
        .json(&serde_json::json!({
            "user_id": user_id,
            "code": code,
        }))
        .send().await
        .map_err(|e| format!("Network error: {}. Please check your internet connection and server URL.", e))?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let result: ApiMessageResponse = serde_json::from_str(&body).unwrap_or(ApiMessageResponse { message: None, error: Some(body.clone()), user_id: None, email: None });

    if status.is_success() {
        Ok(GenericResponse {
            success: true,
            message: result.message.unwrap_or("Email verified successfully.".to_string()),
        })
    } else {
        Err(result.error.unwrap_or(format!("Verification failed: {}", status)))
    }
}

#[tauri::command]
pub async fn resend_otp(
    user_id: String,
    state: State<'_, AppState>,
) -> Result<GenericResponse, String> {
    let server_url = get_server_url(&state.lancedb).await;

    let resp = reqwest::Client::new()
        .post(format!("{}/api/v1/account/resend_otp", server_url))
        .json(&serde_json::json!({ "user_id": user_id }))
        .send().await
        .map_err(|e| format!("Network error: {}. Please check your internet connection and server URL.", e))?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let result: ApiMessageResponse = serde_json::from_str(&body).unwrap_or(ApiMessageResponse { message: None, error: Some(body.clone()), user_id: None, email: None });

    if status.is_success() {
        Ok(GenericResponse {
            success: true,
            message: result.message.unwrap_or("New code sent.".to_string()),
        })
    } else {
        Err(result.error.unwrap_or(format!("Resend failed: {}", status)))
    }
}

#[tauri::command]
pub async fn forgot_password(
    email: String,
    state: State<'_, AppState>,
) -> Result<GenericResponse, String> {
    let server_url = get_server_url(&state.lancedb).await;

    let resp = reqwest::Client::new()
        .post(format!("{}/api/v1/account/forgot_password", server_url))
        .json(&serde_json::json!({ "email": email }))
        .send().await
        .map_err(|e| format!("Network error: {}. Please check your internet connection and server URL.", e))?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let result: ApiMessageResponse = serde_json::from_str(&body).unwrap_or(ApiMessageResponse { message: None, error: Some(body.clone()), user_id: None, email: None });

    Ok(GenericResponse {
        success: status.is_success(),
        message: result.message.unwrap_or("If that email is registered, a reset link has been sent.".to_string()),
    })
}

#[tauri::command]
pub async fn reset_password(
    user_id: String,
    token: String,
    password: String,
    confirm: String,
    state: State<'_, AppState>,
) -> Result<GenericResponse, String> {
    let server_url = get_server_url(&state.lancedb).await;

    let resp = reqwest::Client::new()
        .post(format!("{}/api/v1/account/reset_password", server_url))
        .json(&serde_json::json!({
            "user_id": user_id,
            "token": token,
            "password": password,
            "password_confirmation": confirm
        }))
        .send().await
        .map_err(|e| format!("Network error: {}. Please check your internet connection and server URL.", e))?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let result: ApiMessageResponse = serde_json::from_str(&body).unwrap_or(ApiMessageResponse { message: None, error: Some(body.clone()), user_id: None, email: None });

    if status.is_success() {
        Ok(GenericResponse {
            success: true,
            message: result.message.unwrap_or("Password reset successfully.".to_string()),
        })
    } else {
        Err(result.error.unwrap_or(format!("Reset failed: {}", status)))
    }
}

#[tauri::command]
pub async fn get_stored_did(state: State<'_, AppState>) -> Result<Option<String>, String> {
    if let Ok(Some(batch)) = state.lancedb.get_identity().await {
        let col = batch.column(1).as_any().downcast_ref::<StringArray>()
            .ok_or_else(|| "Invalid identity schema".to_string())?;
        if col.len() > 0 && !col.is_null(0) {
            return Ok(Some(col.value(0).to_string()));
        }
    }
    Ok(None)
}

#[tauri::command]
pub async fn login(
    identifier: String,
    password: String,
    state: State<'_, AppState>,
) -> Result<LoginResponse, String> {
    let server_url = get_server_url(&state.lancedb).await;

    log::info!("Login: {} @ {}", identifier, server_url);

    let client = reqwest::Client::new();

    let token_resp = client
        .post(format!("{}/api/v1/oauth/token", server_url))
        .json(&serde_json::json!({
            "grant_type": "password",
            "username":   identifier,
            "password":   password,
        }))
        .send().await
        .map_err(|e| format!("Network error: {}. Please check your internet connection and server URL.", e))?;

    if !token_resp.status().is_success() {
        let status = token_resp.status();
        let body   = token_resp.text().await.unwrap_or_default();
        log::error!("Token request failed: {} - {}", status, body);
        return Err(format!("Login failed: {} {}", status, body));
    }

    let token_data: serde_json::Value = token_resp.json().await
        .map_err(|e| format!("Failed to parse token response: {}", e))?;

    let access_token = token_data["access_token"]
        .as_str()
        .ok_or_else(|| format!("No access_token in response: {}", token_data))?
        .to_string();

    let did: String =
        if let Some(d) = token_data["did"].as_str().filter(|s| s.starts_with("did:")) {
            d.to_string()
        }
        else if let Some(d) = token_data["account"]["did"].as_str().filter(|s| s.starts_with("did:")) {
            d.to_string()
        }
        else if let Some(me) = token_data["me"].as_str() {
            if me.starts_with("did:") {
                me.to_string()
            } else {
                let segment = me.trim_end_matches('/').split('/').last().unwrap_or(&identifier);
                format!("did:przma:{}", segment)
            }
        }
        else if let Some(id) = token_data["account"]["id"].as_str() {
            format!("did:przma:{}", id)
        }
        else if let Some(id) = token_data["account"]["id"].as_i64() {
            format!("did:przma:{}", id)
        }
        else {
            format!("did:przma:{}", identifier)
        };

    let username = token_data["account"]["username"].as_str()
        .or_else(|| token_data["account"]["acct"].as_str())
        .unwrap_or(&identifier)
        .to_string();

    // Prefer the backend's primary key (user.id) over the DID fingerprint — they must match
    // the owner_user_id stored in ChatRoom and other backend resources.
    let user_id = token_data["user_id"]
        .as_str()
        .map(|s| s.to_string())
        .unwrap_or_else(|| did.splitn(3, ':').nth(2).unwrap_or(&identifier).to_string());


    log::info!("Login OK  username={} did={} user_id={}", username, did, user_id);

    // Also try keyring as secondary (best-effort, don't fail login if it errors)
    let _ = crate::vault::save_token_to_keyring(&access_token);

    use arrow::array::{RecordBatch, StringArray};
    use std::sync::Arc;
    let schema = crate::db::lancedb::LanceDBManager::identity_schema();
    
    let batch = RecordBatch::try_new(schema, vec![
        Arc::new(StringArray::from(vec!["singleton"])),
        Arc::new(StringArray::from(vec![did.clone()])),
        Arc::new(StringArray::from(vec![user_id])),
        Arc::new(StringArray::from(vec![username])),
        Arc::new(StringArray::from(vec![None as Option<&str>])), // email
        Arc::new(StringArray::from(vec![server_url])),
        Arc::new(StringArray::from(vec![None as Option<&str>])), // last_sync_at
        Arc::new(StringArray::from(vec![None as Option<&str>])), // vault_key
        Arc::new(StringArray::from(vec![None as Option<&str>])), // key_salt
        Arc::new(StringArray::from(vec![access_token.clone()])), // access_token ← new
    ]).map_err(|e| e.to_string())?;

    state.lancedb.save_identity(batch).await.map_err(|e| e.to_string())?;
    log::info!("✅ Credentials + access_token saved to LanceDB");

    // Refresh the vault_key in AppState for the new user
    let new_key = crate::vault::load_or_generate_key_lancedb(&state.lancedb)
        .await
        .map_err(|e| format!("Failed to reload vault key: {}", e))?;
    *state.vault_key.write().await = new_key;
    log::info!("🔐 Vault key refreshed in AppState");

    Ok(LoginResponse {
        success:      true,
        did:          Some(did),
        access_token: Some(access_token),
    })
}

#[tauri::command]
pub async fn logout(state: State<'_, AppState>) -> Result<(), String> {
    log::info!("🚪 [Logout] Initiated");
    if let Err(e) = crate::vault::delete_token_from_keyring() {
        log::warn!("🚪 [Logout] Keychain token delete failed (ignoring): {}", e);
    }
    
    state.lancedb.logout().await.map_err(|e| {
        log::error!("🚪 [Logout] LanceDB logout failed: {}", e);
        e.to_string()
    })?;

    log::info!("🚪 [Logout] Successful - token cleared and database reset");
    Ok(())
}

#[tauri::command]
pub async fn clear_local_data(state: tauri::State<'_, AppState>) -> Result<(), String> {
    log::info!("🔴 HARD RESET: Clearing all local data...");
    state.lancedb.logout().await.map_err(|e| e.to_string())?;
    
    // Clear the vault_key in memory too
    *state.vault_key.write().await = crate::vault::VaultKey::default();
    
    log::info!("✅ Local data wiped clean.");
    Ok(())
}

#[derive(Serialize)]
pub struct UserInfo {
    pub username: String,
    pub did: String,
}

#[tauri::command]
pub async fn get_current_user(state: State<'_, AppState>) -> Result<UserInfo, String> {
    if let Ok(Some(batch)) = state.lancedb.get_identity().await {
        let name_col = batch.column(3).as_any().downcast_ref::<StringArray>()
            .ok_or_else(|| "Invalid identity schema".to_string())?;
        let did_col = batch.column(1).as_any().downcast_ref::<StringArray>()
            .ok_or_else(|| "Invalid identity schema".to_string())?;
        
        if name_col.len() > 0 && did_col.len() > 0 {
            return Ok(UserInfo {
                username: name_col.value(0).to_string(),
                did:      did_col.value(0).to_string(),
            });
        }
    }
    Err("No user logged in".to_string())
}

#[tauri::command]
pub async fn get_local_token(
    _state: State<'_, AppState>,
) -> Result<Option<String>, String> {
    match crate::vault::load_token_from_keyring() {
        Ok(opt) => Ok(opt),
        Err(e) => Err(e),
    }
}

#[tauri::command]
pub async fn update_server_url(
    url: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    state.lancedb.update_server_url(&url).await.map_err(|e| e.to_string())?;
    log::info!("[Auth] Server URL updated in LanceDB to: {}", url);
    Ok(())
}