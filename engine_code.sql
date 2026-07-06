-- =========================Support functions ============================
-- ====The example is workin on an schema named DIP =====================
CREATE OR REPLACE FUNCTION DIP.get_first_key(value IN CLOB) RETURN VARCHAR2 IS
    PRAGMA UDF;
    v_json_object json_object_t:=json_object_t.parse(value);
    keys json_key_list;
    v_first_key VARCHAR2(100);
BEGIN
    keys := v_json_object.get_keys();
    v_first_key:=keys(1); --< the first key of the JSON object
    RETURN v_first_key;
EXCEPTION
    WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(-20001, value); value;
END get_first_key;
/
-- ============================================================

SET SERVEROUTPUT ON;

DECLARE
    -- ======== Rule example in JSON format ========
    v_rule_document CLOB:='{
    "rule-id": 1,
    "rule-name": "Recipes to recommend",
    "EVALUATION": {
        "AND" : [
        {
            "field" : "Healthy Recipe",
            "operator" : "=",
            "value" : "YES"
        },
        {
            "OR" : [
            {
                "field" : "Preparation Hours",
                "operator" : "<=",
                "value" : 1
            },
            {
                "field" : "Ingredient Availability",
                "operator" : "in",
                "value" : ["Low", "Medium"]
            }
            ]
        }
        ]
    }
    }';
    type record_type is record (parent_operator VARCHAR2(10), item_type VARCHAR2(10), brach_id NUMERIC(10), leaf_id NUMERIC(10) , json_expression VARCHAR2(1000));
    type table_type is table of record_type;
    v_denormalized_rules table_type;
    v_sql_statement VARCHAR2(1000);
    type branch_output is table of PLS_INTEGER INDEX BY PLS_INTEGER;
    v_brach_output branch_output;
    v_rule_evaluation_output PLS_INTEGER;
    v_current_group_id PLS_INTEGER;
    v_counter PLS_INTEGER:=0;
    FUNCTION check_value_class(value json_element_t) RETURN PLS_INTEGER IS
        v_return PLS_INTEGER:=0;
    BEGIN
	    --Es una arreglo--
        IF value.IS_ARRAY() THEN
            v_return:=2;
        ELSIF regexp_count(value.to_string(), '^-?\d+(\.\d+)?$', 1, 'i') > 0 THEN
            --es numerico--
            v_return:=1;
        ELSE
            --es string--
            v_return:=0;
        END IF;
        RETURN v_return;
    END check_value_class;
    FUNCTION check_if_element_in_array(array_object json_array_t, value VARCHAR2) RETURN PLS_INTEGER IS
        v_return PLS_INTEGER:=0;
    BEGIN
        FOR indx IN 0..array_object.get_size - 1 LOOP
            IF array_object.get_string(indx) = value THEN
                v_return:=1;
                EXIT;
            END IF;
        END LOOP;
        RETURN v_return;
    END check_if_element_in_array;
    FUNCTION inline_execute_logic(data CLOB, rule_table table_type) RETURN PLS_INTEGER IS
        v_current_logic_status PLS_INTEGER:=0;
        v_previous_logic_status PLS_INTEGER;
        v_json_array json_array_t;
        v_json_object_rule json_object_t;
        v_json_object_data json_object_t;
        v_json_input_value_element json_element_t;
        v_rule_field_element json_element_t;
        v_field_operator VARCHAR2(5);
        v_field_name VARCHAR2(100);
        v_field_value VARCHAR2(100);
        v_input_field_value VARCHAR2(100);
        v_rule_value_class PLS_INTEGER;
        type branch_output is table of PLS_INTEGER INDEX BY PLS_INTEGER;
        v_brach_output branch_output;
        match_first PLS_INTEGER:=0;
    BEGIN
        v_json_object_data:=json_object_t.parse(data);
        --Recorriendo la representacion jerarquica de la regla--
        FOR i IN 1..rule_table.count LOOP
            v_json_object_rule:=json_object_t.parse(rule_table(i).json_expression);
            IF rule_table(i).item_type = 'field' THEN --Is a leaf node
            --revisando si es una condicion--
                v_field_name:=v_json_object_rule.get_string('field');
                --revisando si el atributo a evaluar existe en los datos de entrada--
                IF NOT v_json_object_data.has(v_field_name) THEN
                    v_current_logic_status:=0;
                    CONTINUE;
                END IF;
                --Inicializacion de variables
                v_current_logic_status:=0;
                v_json_input_value_element:=v_json_object_data.get(v_field_name);
                v_input_field_value:=v_json_object_data.get_string(v_field_name);
                v_field_operator:=upper(v_json_object_rule.get_string('operator'));
                v_rule_field_element:=v_json_object_rule.get('value');
                v_rule_value_class:=check_value_class(v_rule_field_element);
                v_field_value:=v_json_object_rule.get_string('value');
                --Seccion para determinar la accion por cada tipo de operador
                IF v_field_operator IN ('>', '<', '>=', '<=', '=') THEN
                    --si el valor de entrada es numerico
                    IF check_value_class(v_json_input_value_element) = 1 AND v_rule_value_class = 1 THEN
                        SELECT CASE WHEN v_field_operator = '>' AND TO_NUMBER(v_input_field_value) > TO_NUMBER(v_field_value) THEN 1
                                    WHEN v_field_operator = '<' AND TO_NUMBER(v_input_field_value) < TO_NUMBER(v_field_value) THEN 1
                                    WHEN v_field_operator = '>=' AND TO_NUMBER(v_input_field_value) >= TO_NUMBER(v_field_value) THEN 1
                                    WHEN v_field_operator = '<=' AND TO_NUMBER(v_input_field_value) <= TO_NUMBER(v_field_value) THEN 1
                                    WHEN v_field_operator = '=' AND TO_NUMBER(v_input_field_value) = TO_NUMBER(v_field_value) THEN 1
                                    ELSE 0
                        END INTO v_current_logic_status FROM DUAL;
                    ELSE
                        --si el valor de entrada es una cadena de caracteres
                        SELECT CASE WHEN v_field_operator = '>' AND v_input_field_value > v_field_value THEN 1
                                    WHEN v_field_operator = '<' AND v_input_field_value < v_field_value THEN 1
                                    WHEN v_field_operator = '>=' AND v_input_field_value >= v_field_value THEN 1
                                    WHEN v_field_operator = '<=' AND v_input_field_value <= v_field_value THEN 1
                                    WHEN v_field_operator = '=' AND v_input_field_value = v_field_value THEN 1
                                    ELSE 0
                        END INTO v_current_logic_status FROM DUAL;                    
                    END IF;
                ELSIF v_field_operator = 'IN' THEN
                    --si debo buscar un valor en un arreglo
                    IF v_rule_value_class = 2 THEN
                        v_json_array:=TREAT (v_rule_field_element AS json_array_t);
                        v_current_logic_status:=check_if_element_in_array(v_json_array, v_input_field_value);
                    ELSIF v_rule_value_class = 0 THEN
                        BEGIN
                            v_json_array:=json_array_t.parse(v_field_value);
                            v_current_logic_status:=check_if_element_in_array(v_json_array, v_input_field_value);
                        EXCEPTION
                            WHEN OTHERS THEN
                                --frente a errores decido que la evaluacion no se cumple
                                v_current_logic_status:=0;
                        END;
                    END IF;
                END IF;
                BEGIN --reviso por resultados previos  
                    v_previous_logic_status:=v_brach_output(rule_table(i).brach_id);
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        v_previous_logic_status:=v_current_logic_status;
                END;                
            ELSE --Es una operacion
                v_previous_logic_status:=v_brach_output(rule_table(i).leaf_id);
            END IF;

            --usando el operador logico del nivel comparo con resultados previos
            CASE WHEN rule_table(i).parent_operator = 'OR' AND v_previous_logic_status + v_current_logic_status > 0 THEN
                v_current_logic_status:=1;
                WHEN rule_table(i).parent_operator = 'AND' AND v_previous_logic_status * v_current_logic_status > 0 THEN
                v_current_logic_status:=1;
            ELSE
                v_current_logic_status:=0;
            END CASE;
            v_brach_output(rule_table(i).brach_id):=v_current_logic_status;
        END LOOP;
        RETURN v_current_logic_status;
    END inline_execute_logic;
BEGIN
	-- ======================Split JSON using recursion========================
    WITH json_iterate (priority, operator, evaluation, hierarchy_level, parent_id, id) AS
    (
        SELECT 1 priority, DIP.get_first_key(evaluation) operator, cast(evaluation as varchar2(2000)) evaluation, 1 hierarchy_level, '11' parent_id, '11' id
        FROM json_table(v_rule_document, '$.evaluation' COLUMNS evaluation VARCHAR2(2000) FORMAT JSON PATH '$')
        UNION ALL
        SELECT ROWNUM priority, DIP.get_first_key(child) operator, cast(child as varchar2(2000)) child, json_iterate.hierarchy_level + 1
        , to_char(json_iterate.hierarchy_level) || to_char(json_iterate.priority) parent_id
        , to_char(json_iterate.hierarchy_level + 1) || to_char(ROWNUM) id
        FROM json_iterate, json_table(json_iterate.evaluation, '$.*[*]' COLUMNS child VARCHAR2(2000) FORMAT JSON PATH '$', "CHECK" VARCHAR2(5) EXISTS PATH '$.*') as child
        where child is not null
        and "CHECK" = 'true'
        and hierarchy_level < 100 --< safeguard to avoid infinite recursion
    )
    , parent_operator AS
    (
        SELECT id, operator FROM json_iterate where operator <> 'field'
    )
    select b.operator parent_operator, a.operator item_type, a.parent_id, a.id, a.evaluation
    bulk collect into v_denormalized_rules
    from json_iterate a
    left join parent_operator b on a.parent_id = b.id
    where a.id <> '11' --se excluye el elemento raiz
    order by a.hierarchy_level desc, a.priority;

    --creating sample data to validate my rule engine--
    FOR x IN 
    (
        with sample_data as
        (
            select 'onion' "Primary Ingredient", 1 "Preparation Hours", 'Low' "Ingredient Availability", 'NO' "Pre-cooked", 'YES' "Healthy Recipe" from dual --(1 AND (1 OR 1)) 
            union all
            select 'tomato' "Primary Ingredient", 2 "Preparation Hours", 'Medium' "Ingredient Availability", 'YES' "Pre-cooked", 'NO' "Healthy Recipe" from dual --(0 AND (0 OR 1))
            union all
            select 'onion' "Primary Ingredient", 4 "Preparation Hours", 'Low' "Ingredient Availability", 'YES' "Pre-cooked", 'YES' "Healthy Recipe" from dual --(1 AND (0 OR 1))
            union all
            select 'carrot' "Primary Ingredient", 0.5 "Preparation Hours", 'High' "Ingredient Availability", 'NO' "Pre-cooked", 'NO' "Healthy Recipe" from dual --(0 AND (1 OR 0))
        )
        select JSON_OBJECT(*) json_data from sample_data
    ) LOOP
        v_counter:=v_counter+1;
        v_rule_evaluation_output:=inline_execute_logic(x.json_data, v_denormalized_rules);
        dbms_output.put_line('Input Data: ' || x.json_data);
        dbms_output.put_line('Rule Output: ' || v_rule_evaluation_output);
    END LOOP;
END;