use automerge::{Automerge, ReadDoc, transaction::Transactable};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CRDTDocument {
    pub doc_id: String,
    pub filename: String,
    pub automerge_state: Vec<u8>,
    pub cached_content: String,
    pub device_id: String,
    pub last_modified_at: String,
    pub is_synced: bool,
    pub needs_upload: bool,
}

impl CRDTDocument {
    pub fn new(
        doc_id: String,
        filename: String,
        initial_content: String,
        device_id: String,
    ) -> Result<Self, String> {
        let mut doc = Automerge::new();
        
        // ✅ FIXED: transact returns Result<(), E>, handle it properly
        doc.transact(|tx| {
            tx.put(automerge::ROOT, "text", initial_content.as_str())
                .map_err(|e| format!("Failed to put: {:?}", e))
        }).map_err(|e| format!("Transaction failed: {:?}", e))?;
        
        let automerge_state = doc.save();
        
        Ok(Self {
            doc_id,
            filename,
            automerge_state,
            cached_content: initial_content.clone(),
            device_id,
            last_modified_at: chrono::Utc::now().to_rfc3339(),
            is_synced: false,
            needs_upload: true,
        })
    }
    
    pub fn from_db(
        doc_id: String,
        filename: String,
        automerge_state: Vec<u8>,
        device_id: String,
        last_modified_at: String,
        is_synced: bool,
        needs_upload: bool,
    ) -> Result<Self, String> {
        let doc = Automerge::load(&automerge_state)
            .map_err(|e| format!("Failed to load CRDT: {:?}", e))?;
        
        let cached_content = Self::extract_text(&doc)?;
        
        Ok(Self {
            doc_id,
            filename,
            automerge_state,
            cached_content,
            device_id,
            last_modified_at,
            is_synced,
            needs_upload,
        })
    }
    
    pub fn update_content(&mut self, new_content: String) -> Result<(), String> {
        let mut doc = Automerge::load(&self.automerge_state)
            .map_err(|e| format!("Failed to load CRDT: {:?}", e))?;
        
        // ✅ FIXED: Handle Result properly
        doc.transact(|tx| {
            tx.put(automerge::ROOT, "text", new_content.as_str())
                .map_err(|e| format!("Failed to put: {:?}", e))
        }).map_err(|e| format!("Transaction failed: {:?}", e))?;
        
        self.automerge_state = doc.save();
        self.cached_content = new_content;
        self.last_modified_at = chrono::Utc::now().to_rfc3339();
        self.needs_upload = true;
        self.is_synced = false;
        
        log::info!("✅ [CRDT] Updated document '{}'", self.filename);
        Ok(())
    }
    
    pub fn merge(&mut self, remote_state: &[u8]) -> Result<bool, String> {
        log::info!("🔄 [CRDT] Merging changes for '{}'", self.filename);
        
        let mut local_doc = Automerge::load(&self.automerge_state)
            .map_err(|e| format!("Failed to load local CRDT: {:?}", e))?;
        
        let remote_doc = Automerge::load(remote_state)
            .map_err(|e| format!("Failed to load remote CRDT: {:?}", e))?;
        
        let content_before = Self::extract_text(&local_doc)?;
        
        local_doc.merge(&mut remote_doc.clone())
            .map_err(|e| format!("Merge failed: {:?}", e))?;
        
        let content_after = Self::extract_text(&local_doc)?;
        
        self.automerge_state = local_doc.save();
        self.cached_content = content_after.clone();
        self.last_modified_at = chrono::Utc::now().to_rfc3339();
        
        let changed = content_before != content_after;
        
        if changed {
            log::info!("✅ [CRDT] Merge changed content for '{}'", self.filename);
        } else {
            log::info!("✅ [CRDT] Merge completed (no change) for '{}'", self.filename);
        }
        
        Ok(changed)
    }
    
    pub fn get_content(&self) -> &str {
        &self.cached_content
    }
    
    fn extract_text(doc: &Automerge) -> Result<String, String> {
        match doc.get(automerge::ROOT, "text") {
            Ok(Some((value, _))) => {
                match value {
                    automerge::Value::Scalar(scalar) => {
                        Ok(scalar.to_string())
                    }
                    _ => Err("Text is not a scalar value".to_string()),
                }
            }
            Ok(None) => Ok(String::new()),
            Err(e) => Err(format!("Failed to get text: {:?}", e)),
        }
    }
}